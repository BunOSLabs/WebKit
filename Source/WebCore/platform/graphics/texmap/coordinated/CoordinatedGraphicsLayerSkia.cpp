/*
 * Copyright (C) 2024 Igalia S.L.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "CoordinatedGraphicsLayer.h"

#if USE(COORDINATED_GRAPHICS) && USE(SKIA)
#include "GLContext.h"
#include "GraphicsContextSkia.h"
#include "NicosiaBuffer.h"
#include "PlatformDisplay.h"
#include "SkiaAcceleratedBufferPool.h"
#include <skia/core/SkCanvas.h>
#include <skia/core/SkColorSpace.h>
#include <skia/gpu/GrBackendSurface.h>
#include <skia/gpu/ganesh/SkSurfaceGanesh.h>
#include <skia/gpu/ganesh/gl/GrGLBackendSurface.h>
#include <skia/gpu/ganesh/gl/GrGLDirectContext.h>
#include <skia/gpu/gl/GrGLInterface.h>
#include <skia/gpu/gl/GrGLTypes.h>
#include <wtf/FastMalloc.h>
#include <wtf/RunLoop.h>
#include <wtf/Vector.h>

namespace WebCore {

Ref<Nicosia::Buffer> CoordinatedGraphicsLayer::paintTile(const IntRect& tileRect, const IntRect& mappedTileRect, float contentsScale)
{
    auto paintBuffer = [&](Nicosia::Buffer& buffer) {
        buffer.beginPainting();

        GraphicsContextSkia context(sk_ref_sp(buffer.surface()));
        context.clip(IntRect { IntPoint::zero(), tileRect.size() });

        if (!contentsOpaque()) {
            context.setCompositeOperation(CompositeOperator::Copy);
            context.fillRect(IntRect { IntPoint::zero(), tileRect.size() }, Color::transparentBlack);
            context.setCompositeOperation(CompositeOperator::SourceOver);
        }

        context.translate(-tileRect.x(), -tileRect.y());
        context.scale({ contentsScale, contentsScale });
        paintGraphicsLayerContents(context, mappedTileRect);

        buffer.completePainting();
    };

    if (auto* acceleratedBufferPool = m_coordinator->skiaAcceleratedBufferPool()) {
        auto* glContext = PlatformDisplay::sharedDisplayForCompositing().skiaGLContext();
        RELEASE_ASSERT(glContext);
        GLContext::ScopedGLContextCurrent scopedCurrent(*glContext);
        auto buffer = acceleratedBufferPool->acquireBuffer(tileRect.size(), !contentsOpaque());
        paintBuffer(buffer.get());
        return buffer;
    }

    auto buffer = Nicosia::UnacceleratedBuffer::create(tileRect.size(), contentsOpaque() ? Nicosia::Buffer::NoFlags : Nicosia::Buffer::SupportsAlpha);
    paintBuffer(buffer.get());
    return buffer;
}

Ref<Nicosia::Buffer> CoordinatedGraphicsLayer::paintImage(Image& image)
{
    // FIXME: can we just get the image texture if accelerated or upload the pixels if not acclerated instead of painting?.
    // Always render unaccelerated here for now.
    auto buffer = Nicosia::UnacceleratedBuffer::create(IntSize(image.size()), !image.currentFrameKnownToBeOpaque() ? Nicosia::Buffer::SupportsAlpha : Nicosia::Buffer::NoFlags);
    buffer->beginPainting();
    GraphicsContextSkia context(sk_ref_sp(buffer->surface()));
    IntRect rect { IntPoint::zero(), IntSize { image.size() } };
    context.drawImage(image, rect, rect, ImagePaintingOptions(CompositeOperator::Copy));
    buffer->completePainting();
    return buffer;
}

} // namespace WebCore

#endif // USE(COORDINATED_GRAPHICS) && USE(SKIA)
