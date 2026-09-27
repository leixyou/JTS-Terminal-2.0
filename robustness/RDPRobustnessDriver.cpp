#include <cassert>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "../JTFreeRDPService/JTFreeRDPSafety.h"

#ifndef JTS_FRAMEBUFFER_ONLY
extern "C" int32_t JTSRobustnessSwiftDVCAndReconnect(
    const uint8_t *bytes,
    intptr_t count);
#endif

namespace {

#ifndef JTS_SWIFT_ONLY
constexpr size_t kMaximumFramebufferBytes = 256U * 1024U * 1024U;
constexpr size_t kMaximumSmokeAllocationBytes = 8U * 1024U * 1024U;
#endif

int hexNibble(uint8_t value) {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

bool decodeHexCorpusEnvelope(
    const uint8_t *data,
    size_t size,
    std::vector<uint8_t> *decoded) {
    if (!decoded || size < 4 || std::memcmp(data, "hex:", 4) != 0) {
        return false;
    }

    std::vector<uint8_t> digits;
    digits.reserve(size - 4);
    for (size_t index = 4; index < size; ++index) {
        if (std::isspace(static_cast<unsigned char>(data[index]))) {
            continue;
        }
        if (hexNibble(data[index]) < 0) {
            return false;
        }
        digits.push_back(data[index]);
    }
    if (digits.empty() || (digits.size() & 1U) != 0) {
        return false;
    }

    decoded->clear();
    decoded->reserve(digits.size() / 2U);
    for (size_t index = 0; index < digits.size(); index += 2) {
        decoded->push_back(static_cast<uint8_t>(
            (hexNibble(digits[index]) << 4) | hexNibble(digits[index + 1])));
    }
    return true;
}

#ifndef JTS_SWIFT_ONLY
int64_t readInt64(const uint8_t *data, size_t size, size_t offset) {
    uint64_t value = 0;
    for (size_t index = 0; index < sizeof(value); ++index) {
        const size_t source = offset + index;
        value = (value << 8U) | (source < size ? data[source] : 0U);
    }
    return static_cast<int64_t>(value);
}

void exerciseFramebufferBoundaries(const uint8_t *data, size_t size) {
    const int64_t width = readInt64(data, size, 1);
    const int64_t height = readInt64(data, size, 9);
    const int64_t sourceStride = readInt64(data, size, 49);
    const uint64_t destinationStrideBits =
        static_cast<uint64_t>(readInt64(data, size, 57));
    const uint64_t destinationAllocationBits =
        static_cast<uint64_t>(readInt64(data, size, 65));
    JTFreeRDPFramebufferLayout layout{};
    if (JTFreeRDPValidateFramebufferLayout(
            width,
            height,
            kMaximumFramebufferBytes,
            &layout)) {
        assert(width >= 640 && width <= 7680);
        assert(height >= 480 && height <= 4320);
        assert(layout.bytesPerRow == static_cast<size_t>(width) * 4U);
        assert(layout.allocationSize ==
               layout.bytesPerRow * static_cast<size_t>(height));
        assert(layout.allocationSize <= kMaximumFramebufferBytes);
    }

    int engineStateSentinel = 0;
    int activeInstanceSentinel = 0;
    int otherInstanceSentinel = 0;
    int surfaceSentinel = 0;
    int sourceSentinel = 0;
    int otherSourceSentinel = 0;
    const uint8_t stateFlags = size > 73 ? data[73] : 0;
    const uint8_t sourceFlags = size > 74 ? data[74] : 0;
    const void *engineState =
        (stateFlags & 0x01U) ? &engineStateSentinel : nullptr;
    const void *activeInstance =
        (stateFlags & 0x02U) ? &activeInstanceSentinel : nullptr;
    const void *contextInstance = (stateFlags & 0x04U)
        ? ((stateFlags & 0x08U) ? &otherInstanceSentinel : activeInstance)
        : nullptr;
    const void *surface = (stateFlags & 0x10U) ? &surfaceSentinel : nullptr;
    const bool gdiInitialized = (stateFlags & 0x20U) != 0;
    const bool paintStateValid = JTFreeRDPValidatePaintState(
        engineState,
        activeInstance,
        contextInstance,
        gdiInitialized,
        surface);
    if (paintStateValid) {
        assert(engineState && activeInstance && contextInstance && surface);
        assert(activeInstance == contextInstance);
        assert(gdiInitialized);
    }

    const void *primaryBuffer =
        (sourceFlags & 0x01U) ? &sourceSentinel : nullptr;
    const void *bitmapData = (sourceFlags & 0x02U)
        ? &otherSourceSentinel
        : primaryBuffer;
    const int64_t bitmapWidth =
        (sourceFlags & 0x04U) ? JTFreeRDPSaturatingAddInt64(width, 1) : width;
    const int64_t bitmapHeight =
        (sourceFlags & 0x08U) ? JTFreeRDPSaturatingAddInt64(height, 1) : height;
    uint64_t bitmapStride = static_cast<uint64_t>(sourceStride);
    if (sourceFlags & 0x10U) {
        bitmapStride ^= 1U;
    }
    const bool sourceBitmapValid = JTFreeRDPValidateSourceBitmap(
        width,
        height,
        sourceStride,
        bitmapWidth,
        bitmapHeight,
        bitmapStride,
        primaryBuffer,
        bitmapData);
    if (sourceBitmapValid) {
        assert(primaryBuffer == bitmapData);
        assert(width == bitmapWidth && height == bitmapHeight);
        assert(sourceStride >= 0);
        assert(static_cast<uint64_t>(sourceStride) == bitmapStride);
    }

    JTFreeRDPSurfaceCopyLayout copyLayout{};
    if (destinationStrideBits <= std::numeric_limits<size_t>::max() &&
        destinationAllocationBits <= std::numeric_limits<size_t>::max() &&
        JTFreeRDPValidateSurfaceCopyLayout(
            width,
            height,
            sourceStride,
            static_cast<size_t>(destinationStrideBits),
            static_cast<size_t>(destinationAllocationBits),
            kMaximumFramebufferBytes,
            &copyLayout)) {
        assert(copyLayout.sourceStride >= layout.bytesPerRow);
        assert(copyLayout.destinationStride >= layout.bytesPerRow);
        assert(copyLayout.sourceRequiredBytes ==
               copyLayout.sourceStride * static_cast<size_t>(height));
        assert(copyLayout.destinationRequiredBytes <=
               static_cast<size_t>(destinationAllocationBits));
        assert(copyLayout.destinationRequiredBytes <= kMaximumFramebufferBytes);
    }

    const int64_t dirtyX = readInt64(data, size, 17);
    const int64_t dirtyY = readInt64(data, size, 25);
    const int64_t dirtyWidth = readInt64(data, size, 33);
    const int64_t dirtyHeight = readInt64(data, size, 41);
    JTFreeRDPDirtyRect rect{};
    if (!JTFreeRDPIntersectDirtyRect(
            width,
            height,
            dirtyX,
            dirtyY,
            dirtyWidth,
            dirtyHeight,
            &rect)) {
        return;
    }

    assert(rect.x >= 0 && rect.y >= 0);
    assert(rect.width > 0 && rect.height > 0);
    assert(static_cast<int64_t>(rect.x) + rect.width <= width);
    assert(static_cast<int64_t>(rect.y) + rect.height <= height);

    JTFreeRDPCopyRegion region{};
    if (JTFreeRDPValidateCopyRegion(
            width,
            height,
            &copyLayout,
            rect,
            &region)) {
        assert(region.rowBytes == static_cast<size_t>(rect.width) * 4U);
        assert(region.sourceFirstByteOffset <= region.sourceLastByteOffset);
        assert(region.destinationFirstByteOffset <=
               region.destinationLastByteOffset);
        assert(region.sourceLastByteOffset < copyLayout.sourceRequiredBytes);
        assert(region.destinationLastByteOffset <
               copyLayout.destinationRequiredBytes);

        if (copyLayout.sourceRequiredBytes <= kMaximumSmokeAllocationBytes &&
            destinationAllocationBits <= kMaximumSmokeAllocationBytes) {
            std::vector<uint8_t> source(copyLayout.sourceRequiredBytes, 0xA5U);
            std::vector<uint8_t> destination(
                static_cast<size_t>(destinationAllocationBits),
                0U);
            assert(region.sourceLastByteOffset < source.size());
            assert(region.destinationLastByteOffset < destination.size());
            for (int32_t row = 0; row < rect.height; ++row) {
                std::memcpy(
                    destination.data() + region.destinationFirstByteOffset +
                        static_cast<size_t>(row) * copyLayout.destinationStride,
                    source.data() + region.sourceFirstByteOffset +
                        static_cast<size_t>(row) * copyLayout.sourceStride,
                    region.rowBytes);
            }
            assert(destination[region.destinationLastByteOffset] == 0xA5U);
        }
    }
}
#endif

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!data || size == 0) {
        return 0;
    }

    std::vector<uint8_t> decoded;
    if (decodeHexCorpusEnvelope(data, size, &decoded)) {
        data = decoded.data();
        size = decoded.size();
    }
    if (size == 0) {
        return 0;
    }

    // Build scripts produce separate binaries so their corpora and evidence
    // remain attributable. The default combined mode is useful for ad-hoc
    // debugging but is not used to claim complete FreeRDP parser coverage.
#ifndef JTS_FRAMEBUFFER_ONLY
    JTSRobustnessSwiftDVCAndReconnect(data, static_cast<intptr_t>(size));
#endif
#ifndef JTS_SWIFT_ONLY
    exerciseFramebufferBoundaries(data, size);
#endif
    return 0;
}
