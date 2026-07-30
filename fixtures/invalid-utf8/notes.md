# invalid-utf8

A lone 0xE9 where a two-byte sequence belongs — the classic Latin-1 paste.
Must not crash and must not be mangled into replacement characters (DEC-044):
content that is not valid UTF-8 is declared unrenderable with a notice.
