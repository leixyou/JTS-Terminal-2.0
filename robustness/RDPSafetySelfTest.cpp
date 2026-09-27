#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "../JTFreeRDPService/JTFreeRDPSafety.h"

namespace {

constexpr size_t kMaximumFramebufferBytes = 256U * 1024U * 1024U;

void testCheckedArithmetic() {
    size_t result = 0;
    assert(JTFreeRDPCheckedMultiplySize(640U, 4U, &result));
    assert(result == 2560U);
    assert(!JTFreeRDPCheckedMultiplySize(
        std::numeric_limits<size_t>::max(),
        2U,
        &result));
    assert(JTFreeRDPCheckedAddSize(1U, 2U, &result));
    assert(result == 3U);
    assert(!JTFreeRDPCheckedAddSize(
        std::numeric_limits<size_t>::max(),
        1U,
        &result));
}

void testStateAndSourceIdentity() {
    int engineState = 0;
    int activeInstance = 0;
    int staleInstance = 0;
    int surface = 0;
    int pixels = 0;

    assert(JTFreeRDPValidatePaintState(
        &engineState,
        &activeInstance,
        &activeInstance,
        true,
        &surface));
    assert(!JTFreeRDPValidatePaintState(
        &engineState,
        &activeInstance,
        &staleInstance,
        true,
        &surface));
    assert(!JTFreeRDPValidatePaintState(
        &engineState,
        &activeInstance,
        &activeInstance,
        false,
        &surface));
    assert(!JTFreeRDPValidatePaintState(
        nullptr,
        &activeInstance,
        &activeInstance,
        true,
        &surface));

    assert(JTFreeRDPValidateSourceBitmap(
        640,
        480,
        2560,
        640,
        480,
        2560,
        &pixels,
        &pixels));
    assert(!JTFreeRDPValidateSourceBitmap(
        640,
        480,
        2560,
        641,
        480,
        2560,
        &pixels,
        &pixels));
    assert(!JTFreeRDPValidateSourceBitmap(
        640,
        480,
        2560,
        640,
        480,
        2560,
        &pixels,
        &surface));
}

void testFramebufferAndIOSurfaceBounds() {
    JTFreeRDPFramebufferLayout framebuffer{};
    assert(JTFreeRDPValidateFramebufferLayout(
        640,
        480,
        kMaximumFramebufferBytes,
        &framebuffer));
    assert(framebuffer.bytesPerRow == 2560U);
    assert(framebuffer.allocationSize == 1'228'800U);
    assert(!JTFreeRDPValidateFramebufferLayout(
        639,
        480,
        kMaximumFramebufferBytes,
        nullptr));

    JTFreeRDPSurfaceCopyLayout copy{};
    assert(JTFreeRDPValidateSurfaceCopyLayout(
        640,
        480,
        2560,
        2560,
        framebuffer.allocationSize,
        kMaximumFramebufferBytes,
        &copy));
    assert(copy.sourceRequiredBytes == framebuffer.allocationSize);
    assert(copy.destinationRequiredBytes == framebuffer.allocationSize);
    assert(!JTFreeRDPValidateSurfaceCopyLayout(
        640,
        480,
        2559,
        2560,
        framebuffer.allocationSize,
        kMaximumFramebufferBytes,
        nullptr));
    assert(!JTFreeRDPValidateSurfaceCopyLayout(
        640,
        480,
        2560,
        2560,
        framebuffer.allocationSize - 1,
        kMaximumFramebufferBytes,
        nullptr));
}

void testDirtyRectLastByte() {
    JTFreeRDPSurfaceCopyLayout copy{};
    assert(JTFreeRDPValidateSurfaceCopyLayout(
        640,
        480,
        2560,
        2560,
        1'228'800U,
        kMaximumFramebufferBytes,
        &copy));

    JTFreeRDPDirtyRect edgePixel{};
    assert(JTFreeRDPIntersectDirtyRect(
        640,
        480,
        639,
        479,
        1,
        1,
        &edgePixel));
    JTFreeRDPCopyRegion region{};
    assert(JTFreeRDPValidateCopyRegion(
        640,
        480,
        &copy,
        edgePixel,
        &region));
    assert(region.rowBytes == 4U);
    assert(region.sourceLastByteOffset == copy.sourceRequiredBytes - 1U);
    assert(region.destinationLastByteOffset ==
           copy.destinationRequiredBytes - 1U);

    JTFreeRDPDirtyRect clipped{};
    assert(JTFreeRDPIntersectDirtyRect(
        640,
        480,
        -10,
        -20,
        20,
        40,
        &clipped));
    assert(clipped.x == 0 && clipped.y == 0);
    assert(clipped.width == 10 && clipped.height == 20);
    assert(JTFreeRDPValidateCopyRegion(
        640,
        480,
        &copy,
        clipped,
        nullptr));

    JTFreeRDPSurfaceCopyLayout truncated = copy;
    truncated.sourceRequiredBytes -= 1U;
    assert(!JTFreeRDPValidateCopyRegion(
        640,
        480,
        &truncated,
        edgePixel,
        nullptr));

    JTFreeRDPDirtyRect outside = { 639, 479, 2, 1 };
    assert(!JTFreeRDPValidateCopyRegion(
        640,
        480,
        &copy,
        outside,
        nullptr));
}

}  // namespace

int main() {
    testCheckedArithmetic();
    testStateAndSourceIdentity();
    testFramebufferAndIOSurfaceBounds();
    testDirtyRectLastByte();
    return 0;
}
