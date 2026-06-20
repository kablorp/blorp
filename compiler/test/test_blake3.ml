let vector_input len = String.init len (fun i -> Char.chr (i mod 251))

let expect_hash len expected =
  let actual = Blorp.Blake3.hash_string_hex (vector_input len) in
  Alcotest.(check string) (Printf.sprintf "len %d" len) expected actual

let test_official_hash_vectors () =
  List.iter
    (fun (len, expected) -> expect_hash len expected)
    [
      (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
      (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213");
      (63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b");
      (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98");
      (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee");
      (1023, "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11");
      (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7");
      (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444");
      (2048, "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a");
      (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030");
      (4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969");
      (4097, "9b4052b38f1c5fc8b1f9ff7ac7b27cd242487b3d890d15c96a1c25b8aa0fb995");
      (16384, "f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4");
      (31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47");
    ]

let test_incremental_updates_match_one_shot () =
  let input = vector_input 4097 in
  let one_shot = Blorp.Blake3.hash_string_hex input in
  let hasher = Blorp.Blake3.create () in
  Blorp.Blake3.update hasher (String.sub input 0 17);
  Blorp.Blake3.update hasher (String.sub input 17 1000);
  Blorp.Blake3.update hasher
    (String.sub input 1017 (String.length input - 1017));
  let incremental =
    Blorp.Blake3.finalize hasher Blorp.Blake3.out_len |> Blorp.Blake3.to_hex
  in
  Alcotest.(check string) "incremental" one_shot incremental

let suite =
  [
    ( "hash",
      [
        Alcotest.test_case "official hash vectors" `Quick
          test_official_hash_vectors;
        Alcotest.test_case "incremental updates match one shot" `Quick
          test_incremental_updates_match_one_shot;
      ] );
  ]
