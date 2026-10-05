"""Test-only helpers for deliberately malformed version-1 application images."""
import struct

MAGIC = b"BABET_IMAGE_15_f419b2a67e8c930d!"


def marker_offset(image):
    offset = image.find(MAGIC)
    assert offset >= 0 and image.find(MAGIC, offset + 1) < 0, "expected one image descriptor"
    assert offset + 64 <= len(image)
    return offset


def update_checksum(image, offset):
    value = 14695981039346656037
    for byte in image[offset:offset + 56]:
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    struct.pack_into("<Q", image, offset + 56, value)


def replace_archive(image, archive):
    """Preserve the executable prefix, update its descriptor, replace the ZIP."""
    offset = marker_offset(image)
    version, generated, start, _ = struct.unpack_from("<IIQQ", image, offset + 32)
    assert version == 1 and generated in (0, 1)
    prefix_size = start if generated else len(image)
    result = bytearray(image[:prefix_size])
    struct.pack_into("<IIQQ", result, offset + 32, 1, 1, prefix_size, len(archive))
    update_checksum(result, offset)
    return bytes(result) + archive
