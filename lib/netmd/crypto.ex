defmodule NetMD.Crypto do
  @moduledoc """
  DES primitives for the NetMD secure session, matching the CryptoJS
  usage in netmd-js. All inputs must be multiples of the 8-byte DES block
  size; the reference relies on the same alignment.
  """

  @zero_iv <<0, 0, 0, 0, 0, 0, 0, 0>>

  @doc "Single-DES ECB encryption."
  @spec des_ecb_encrypt(key :: <<_::64>>, binary()) :: binary()
  def des_ecb_encrypt(key, data), do: :crypto.crypto_one_time(:des_ecb, key, data, true)

  @doc "Single-DES ECB decryption."
  @spec des_ecb_decrypt(key :: <<_::64>>, binary()) :: binary()
  def des_ecb_decrypt(key, data), do: :crypto.crypto_one_time(:des_ecb, key, data, false)

  @doc "Single-DES CBC encryption."
  @spec des_cbc_encrypt(key :: <<_::64>>, iv :: <<_::64>>, binary()) :: binary()
  def des_cbc_encrypt(key, iv, data),
    do: :crypto.crypto_one_time(:des_cbc, key, iv, data, true)

  @doc "Single-DES CBC decryption."
  @spec des_cbc_decrypt(key :: <<_::64>>, iv :: <<_::64>>, binary()) :: binary()
  def des_cbc_decrypt(key, iv, data),
    do: :crypto.crypto_one_time(:des_cbc, key, iv, data, false)

  @factory_key <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77>>

  @doc """
  Encrypt data for an encrypted factory memory transfer.

  Matches the reference: PKCS7-pad to the DES block size, ECB-encrypt with
  the fixed factory key, then drop the trailing padding block. For
  block-aligned input (what the callers produce) this is plain ECB.
  """
  @spec factory_transfer_encrypt(binary()) :: binary()
  def factory_transfer_encrypt(data) do
    padded = pkcs7_pad(data, 8)
    encrypted = des_ecb_encrypt(@factory_key, padded)
    binary_part(encrypted, 0, byte_size(encrypted) - 8)
  end

  @doc """
  Decrypt data from an encrypted factory memory transfer (block-aligned).
  """
  @spec factory_transfer_decrypt(binary()) :: binary()
  def factory_transfer_decrypt(data), do: des_ecb_decrypt(@factory_key, data)

  defp pkcs7_pad(data, block_size) do
    pad = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad>>, pad)
  end

  @doc """
  Two-key triple-DES CBC encryption (the 16-byte key expands to K1 K2 K1).
  """
  @spec des3_cbc_encrypt(key :: <<_::128>>, iv :: <<_::64>>, binary()) :: binary()
  def des3_cbc_encrypt(<<k1::binary-size(8), _k2::binary-size(8)>> = key, iv, data),
    do: :crypto.crypto_one_time(:des_ede3_cbc, key <> k1, iv, data, true)

  @doc """
  The retail MAC used to derive the secure session key.

  DES-CBC over all but the last 8 bytes of `value` with the first half of
  `key` produces an intermediate IV; triple-DES-CBC over the final 8
  bytes with the full key produces the MAC (first 8 bytes).
  """
  @spec retailmac(key :: <<_::128>>, value :: binary(), iv :: <<_::64>>) :: <<_::64>>
  def retailmac(key, value, iv \\ @zero_iv) do
    <<subkey_a::binary-size(8), _rest::binary>> = key
    beginning_size = byte_size(value) - 8
    <<beginning::binary-size(^beginning_size), ending::binary-size(8)>> = value

    intermediate = des_cbc_encrypt(subkey_a, iv, beginning)
    # The reference feeds the whole intermediate ciphertext to CryptoJS,
    # which only uses the first block as IV.
    iv2 = binary_part(intermediate, 0, 8)

    binary_part(des3_cbc_encrypt(key, iv2, ending), 0, 8)
  end
end
