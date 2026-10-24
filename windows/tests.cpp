static int selfTest() {
  for (int codec = 0; codec < 3; codec++) {
    Document d;
    d.encoding = codec;
    d.crlf = true;
    d.text = L"中😀\ntext";
    int actual = -1;
    auto bytes = encode(d);
    if (decode(bytes, actual) != L"中😀\r\ntext" || actual != codec)
      return 1;
    d.crlf = false;
    if (decode(encode(d), actual) != d.text)
      return 2;
  }
  int codec = 0;
  try {
    decode(std::string("\xff"), codec);
    return 3;
  } catch (const std::exception &) {
  }
  try {
    decode(std::string("\xff\xfe\x41", 3), codec);
    return 4;
  } catch (const std::exception &) {
  }
  return 0;
}
