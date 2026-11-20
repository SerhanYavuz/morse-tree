# Vendor

`codec2/` holds the core of Codec2 (https://github.com/drowe67/codec2), David Rowe's
open-source low-bitrate speech codec, licensed LGPL-2.1 (see `codec2/COPYING`).
Only the files needed for the 700C mode are compiled into the app. The `codebook*.c`
files were generated from the codebook/*.txt data in the Codec2 repository with Codec2's own
`generate_codebook` tool, and `version.h` replaces the CMake-generated header.
