defmodule NetMD.CryptoTest do
  use ExUnit.Case, async: true

  alias NetMD.Crypto
  alias NetMD.Track

  @zero_iv <<0::64>>

  vectors =
    "../fixtures/crypto_vectors.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> JSON.decode!()

  @retailmac_vectors vectors["retailmac"]
  @ecb_vectors vectors["ecb_decrypt"]
  @cbc_vectors vectors["cbc_chain"]
  @setup_vector vectors["setup_download"]
  @commit_vector vectors["commit_track"]

  defp unhex(hex), do: Base.decode16!(hex, case: :lower)

  test "retailmac matches the reference" do
    for %{"key" => key, "value" => value, "mac" => mac} <- @retailmac_vectors do
      assert Crypto.retailmac(unhex(key), unhex(value)) == unhex(mac)
    end
  end

  test "packet key derivation matches CryptoJS DES-ECB decrypt" do
    for %{"kek" => kek, "raw_key" => raw_key, "packet_key" => packet_key} <- @ecb_vectors do
      assert Crypto.des_ecb_decrypt(unhex(kek), unhex(raw_key)) == unhex(packet_key)
    end
  end

  test "chained CBC chunks match CryptoJS" do
    for %{"key" => key, "chunks" => chunks} <- @cbc_vectors do
      for %{"iv" => iv, "data" => data, "encrypted" => encrypted} <- chunks do
        assert Crypto.des_cbc_encrypt(unhex(key), unhex(iv), unhex(data)) == unhex(encrypted)
      end
    end
  end

  test "setup_download message encryption matches the reference" do
    %{
      "session_key" => session_key,
      "content_id" => content_id,
      "kek" => kek,
      "encrypted" => encrypted
    } = @setup_vector

    message = <<1, 1, 1, 1>> <> unhex(content_id) <> unhex(kek)
    assert Crypto.des_cbc_encrypt(unhex(session_key), @zero_iv, message) == unhex(encrypted)
  end

  test "commit_track authentication matches the reference" do
    %{"session_key" => session_key, "auth" => auth} = @commit_vector
    assert Crypto.des_ecb_encrypt(unhex(session_key), @zero_iv) == unhex(auth)
  end

  describe "Track.packets/1" do
    test "chains IVs and derives the packet key from the KEK" do
      raw_key = <<1, 2, 3, 4, 5, 6, 7, 8>>
      data = :binary.copy(<<0xAB>>, 96)

      track = %Track{
        title: "t",
        format: :lp4,
        data: data,
        chunk_size: 56,
        raw_key: raw_key
      }

      packets = Enum.to_list(Track.packets(track))
      # 96 bytes at chunk size 56: first chunk is 56 - 24 = 32, then 56, then 8.
      assert [{key, <<0::64>>, first}, {key, iv2, second}, {key, iv3, third}] = packets
      assert key == Crypto.des_ecb_decrypt(Track.kek(), raw_key)
      assert byte_size(first) == 32
      assert byte_size(second) == 56
      assert byte_size(third) == 8
      assert iv2 == binary_part(first, 24, 8)
      assert iv3 == binary_part(second, 48, 8)

      # The concatenated ciphertext is one continuous CBC stream.
      assert Crypto.des_cbc_decrypt(raw_key, <<0::64>>, first <> second <> third) == data
    end

    test "pads data to a whole number of frames" do
      track = %Track{title: "t", format: :lp4, data: <<1, 2, 3>>}
      assert Track.total_size(track) == 96
      assert Track.frame_count(track) == 1
    end
  end
end
