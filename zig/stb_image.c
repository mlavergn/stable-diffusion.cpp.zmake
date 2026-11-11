// stb_image's implementation for pixdiff, from the pinned sources'
// thirdparty/stb_image.h (build.zig puts that directory on the include path).
// Only the decoders pixdiff reads are compiled.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"
