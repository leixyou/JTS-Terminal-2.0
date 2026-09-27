#ifndef JTFreeRDPSafety_h
#define JTFreeRDPSafety_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    size_t bytesPerRow;
    size_t allocationSize;
} JTFreeRDPFramebufferLayout;

typedef struct {
    size_t sourceStride;
    size_t sourceRequiredBytes;
    size_t destinationStride;
    size_t destinationRequiredBytes;
} JTFreeRDPSurfaceCopyLayout;

typedef struct {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
} JTFreeRDPDirtyRect;

typedef struct {
    size_t sourceFirstByteOffset;
    size_t sourceLastByteOffset;
    size_t destinationFirstByteOffset;
    size_t destinationLastByteOffset;
    size_t rowBytes;
} JTFreeRDPCopyRegion;

static inline bool JTFreeRDPCheckedMultiplySize(
    size_t lhs,
    size_t rhs,
    size_t *result)
{
    if ((lhs != 0) && (rhs > SIZE_MAX / lhs)) {
        return false;
    }
    if (result) {
        *result = lhs * rhs;
    }
    return true;
}

static inline bool JTFreeRDPCheckedAddSize(
    size_t lhs,
    size_t rhs,
    size_t *result)
{
    if (rhs > SIZE_MAX - lhs) {
        return false;
    }
    if (result) {
        *result = lhs + rhs;
    }
    return true;
}

/// Rejects stale/mismatched paint callbacks before dereferencing session-owned
/// framebuffer state. A callback is valid during PostConnect painting once GDI
/// has initialized; it need not wait for the outer event loop to mark the
/// session connected.
static inline bool JTFreeRDPValidatePaintState(
    const void *engineState,
    const void *activeInstance,
    const void *contextInstance,
    bool gdiInitialized,
    const void *surface)
{
    return engineState && activeInstance &&
           (activeInstance == contextInstance) && gdiInitialized && surface;
}

/// Confirms that the public FreeRDP primary-buffer pointer and its owning GDI
/// bitmap still describe the same allocation contract before a copy begins.
static inline bool JTFreeRDPValidateSourceBitmap(
    int64_t width,
    int64_t height,
    int64_t sourceStride,
    int64_t bitmapWidth,
    int64_t bitmapHeight,
    uint64_t bitmapStride,
    const void *primaryBuffer,
    const void *bitmapData)
{
    if (!primaryBuffer || !bitmapData || primaryBuffer != bitmapData ||
        width != bitmapWidth || height != bitmapHeight || sourceStride < 0) {
        return false;
    }
    return (uint64_t)sourceStride == bitmapStride;
}

/// Validates the dimensions and all multiplication used to allocate a BGRA32
/// framebuffer. Kept header-only so the production XPC helper and sanitizer
/// robustness target execute exactly the same boundary logic.
static inline bool JTFreeRDPValidateFramebufferLayout(
    int64_t width,
    int64_t height,
    size_t maximumBytes,
    JTFreeRDPFramebufferLayout *layout)
{
    if (width < 640 || width > 7680 || height < 480 || height > 4320 ||
        (uint64_t)width > SIZE_MAX / 4) {
        return false;
    }

    size_t bytesPerRow = 0;
    if (!JTFreeRDPCheckedMultiplySize((size_t)width, 4, &bytesPerRow)) {
        return false;
    }
    size_t allocationSize = 0;
    if (!JTFreeRDPCheckedMultiplySize(
            bytesPerRow,
            (size_t)height,
            &allocationSize)) {
        return false;
    }
    if (allocationSize > maximumBytes) {
        return false;
    }

    if (layout) {
        layout->bytesPerRow = bytesPerRow;
        layout->allocationSize = allocationSize;
    }
    return true;
}

/// Validates both source and destination row-stride multiplications plus the
/// actual IOSurface allocation before any framebuffer pointer arithmetic or
/// memcpy. FreeRDP does not expose a byte-length field for its primary bitmap;
/// callers must additionally validate its bitmap metadata and backing pointer
/// with `JTFreeRDPValidateSourceBitmap`.
static inline bool JTFreeRDPValidateSurfaceCopyLayout(
    int64_t width,
    int64_t height,
    int64_t sourceStride,
    size_t destinationStride,
    size_t destinationAllocationSize,
    size_t maximumBytes,
    JTFreeRDPSurfaceCopyLayout *layout)
{
    JTFreeRDPFramebufferLayout framebuffer = { 0, 0 };
    if (!JTFreeRDPValidateFramebufferLayout(
            width,
            height,
            maximumBytes,
            &framebuffer) ||
        sourceStride < 0 ||
        (uint64_t)sourceStride > SIZE_MAX) {
        return false;
    }

    const size_t safeSourceStride = (size_t)sourceStride;
    if (safeSourceStride < framebuffer.bytesPerRow ||
        safeSourceStride > maximumBytes ||
        destinationStride < framebuffer.bytesPerRow ||
        destinationStride > maximumBytes) {
        return false;
    }

    size_t sourceRequiredBytes = 0;
    size_t destinationRequiredBytes = 0;
    if (!JTFreeRDPCheckedMultiplySize(
            safeSourceStride,
            (size_t)height,
            &sourceRequiredBytes) ||
        !JTFreeRDPCheckedMultiplySize(
            destinationStride,
            (size_t)height,
            &destinationRequiredBytes) ||
        sourceRequiredBytes > maximumBytes ||
        destinationRequiredBytes > maximumBytes ||
        destinationAllocationSize < destinationRequiredBytes ||
        destinationAllocationSize > maximumBytes) {
        return false;
    }

    if (layout) {
        layout->sourceStride = safeSourceStride;
        layout->sourceRequiredBytes = sourceRequiredBytes;
        layout->destinationStride = destinationStride;
        layout->destinationRequiredBytes = destinationRequiredBytes;
    }
    return true;
}

/// Proves the first and final byte touched by a dirty-rectangle row copy are
/// inside both validated buffers. This check is intentionally separate from
/// rectangle intersection so every memcpy uses byte-level bounds, including
/// the last row and last pixel.
static inline bool JTFreeRDPValidateCopyRegion(
    int64_t framebufferWidth,
    int64_t framebufferHeight,
    const JTFreeRDPSurfaceCopyLayout *layout,
    JTFreeRDPDirtyRect rect,
    JTFreeRDPCopyRegion *region)
{
    if (!layout || framebufferWidth <= 0 || framebufferHeight <= 0 ||
        rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0) {
        return false;
    }

    const int64_t right = (int64_t)rect.x + rect.width;
    const int64_t bottom = (int64_t)rect.y + rect.height;
    if (right > framebufferWidth || bottom > framebufferHeight) {
        return false;
    }

    size_t xBytes = 0;
    size_t rowBytes = 0;
    if (!JTFreeRDPCheckedMultiplySize((size_t)rect.x, 4, &xBytes) ||
        !JTFreeRDPCheckedMultiplySize((size_t)rect.width, 4, &rowBytes)) {
        return false;
    }

    size_t rowEnd = 0;
    if (!JTFreeRDPCheckedAddSize(xBytes, rowBytes, &rowEnd) ||
        rowEnd > layout->sourceStride ||
        rowEnd > layout->destinationStride) {
        return false;
    }

    const size_t firstRow = (size_t)rect.y;
    const size_t lastRow = (size_t)(bottom - 1);
    size_t sourceFirstRowOffset = 0;
    size_t destinationFirstRowOffset = 0;
    size_t sourceLastRowOffset = 0;
    size_t destinationLastRowOffset = 0;
    if (!JTFreeRDPCheckedMultiplySize(
            firstRow,
            layout->sourceStride,
            &sourceFirstRowOffset) ||
        !JTFreeRDPCheckedMultiplySize(
            firstRow,
            layout->destinationStride,
            &destinationFirstRowOffset) ||
        !JTFreeRDPCheckedMultiplySize(
            lastRow,
            layout->sourceStride,
            &sourceLastRowOffset) ||
        !JTFreeRDPCheckedMultiplySize(
            lastRow,
            layout->destinationStride,
            &destinationLastRowOffset)) {
        return false;
    }

    size_t sourceFirstByteOffset = 0;
    size_t destinationFirstByteOffset = 0;
    size_t sourceLastByteExclusive = 0;
    size_t destinationLastByteExclusive = 0;
    if (!JTFreeRDPCheckedAddSize(
            sourceFirstRowOffset,
            xBytes,
            &sourceFirstByteOffset) ||
        !JTFreeRDPCheckedAddSize(
            destinationFirstRowOffset,
            xBytes,
            &destinationFirstByteOffset) ||
        !JTFreeRDPCheckedAddSize(
            sourceLastRowOffset,
            rowEnd,
            &sourceLastByteExclusive) ||
        !JTFreeRDPCheckedAddSize(
            destinationLastRowOffset,
            rowEnd,
            &destinationLastByteExclusive) ||
        sourceLastByteExclusive == 0 || destinationLastByteExclusive == 0 ||
        sourceLastByteExclusive > layout->sourceRequiredBytes ||
        destinationLastByteExclusive > layout->destinationRequiredBytes) {
        return false;
    }

    if (region) {
        region->sourceFirstByteOffset = sourceFirstByteOffset;
        region->sourceLastByteOffset = sourceLastByteExclusive - 1;
        region->destinationFirstByteOffset = destinationFirstByteOffset;
        region->destinationLastByteOffset = destinationLastByteExclusive - 1;
        region->rowBytes = rowBytes;
    }
    return true;
}

static inline int64_t JTFreeRDPSaturatingAddInt64(int64_t lhs, int64_t rhs)
{
    if (rhs > 0 && lhs > INT64_MAX - rhs) {
        return INT64_MAX;
    }
    if (rhs < 0 && lhs < INT64_MIN - rhs) {
        return INT64_MIN;
    }
    return lhs + rhs;
}

/// Intersects an untrusted FreeRDP invalid rectangle with the framebuffer.
/// All arithmetic is widened and saturating before conversion back to INT32.
static inline bool JTFreeRDPIntersectDirtyRect(
    int64_t framebufferWidth,
    int64_t framebufferHeight,
    int64_t dirtyX,
    int64_t dirtyY,
    int64_t dirtyWidth,
    int64_t dirtyHeight,
    JTFreeRDPDirtyRect *result)
{
    if (framebufferWidth <= 0 || framebufferWidth > INT32_MAX ||
        framebufferHeight <= 0 || framebufferHeight > INT32_MAX ||
        dirtyWidth <= 0 || dirtyHeight <= 0) {
        return false;
    }

    int64_t left = dirtyX > 0 ? dirtyX : 0;
    int64_t top = dirtyY > 0 ? dirtyY : 0;
    int64_t right = JTFreeRDPSaturatingAddInt64(dirtyX, dirtyWidth);
    int64_t bottom = JTFreeRDPSaturatingAddInt64(dirtyY, dirtyHeight);
    if (right > framebufferWidth) {
        right = framebufferWidth;
    }
    if (bottom > framebufferHeight) {
        bottom = framebufferHeight;
    }
    if (left >= framebufferWidth || top >= framebufferHeight ||
        right <= left || bottom <= top) {
        return false;
    }

    if (result) {
        result->x = (int32_t)left;
        result->y = (int32_t)top;
        result->width = (int32_t)(right - left);
        result->height = (int32_t)(bottom - top);
    }
    return true;
}

#endif /* JTFreeRDPSafety_h */
