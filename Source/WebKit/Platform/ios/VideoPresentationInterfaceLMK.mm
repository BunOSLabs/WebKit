/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "VideoPresentationInterfaceLMK.h"

#if ENABLE(LINEAR_MEDIA_PLAYER)

#import "PlaybackSessionInterfaceLMK.h"
#import "WKSLinearMediaPlayer.h"
#import "WKSLinearMediaTypes.h"
#import <UIKit/UIKit.h>
#import <WebCore/WebAVPlayerLayerView.h>
#import <pal/spi/vision/LinearMediaKitSPI.h>

namespace WebKit {

VideoPresentationInterfaceLMK::~VideoPresentationInterfaceLMK()
{
}

Ref<VideoPresentationInterfaceLMK> VideoPresentationInterfaceLMK::create(PlaybackSessionInterfaceIOS& playbackSessionInterface)
{
    return adoptRef(*new VideoPresentationInterfaceLMK(playbackSessionInterface));
}

VideoPresentationInterfaceLMK::VideoPresentationInterfaceLMK(PlaybackSessionInterfaceIOS& playbackSessionInterface)
    : VideoPresentationInterfaceIOS { playbackSessionInterface }
{
}

WKSLinearMediaPlayer *VideoPresentationInterfaceLMK::linearMediaPlayer() const
{
    return playbackSessionInterface().linearMediaPlayer();
}

void VideoPresentationInterfaceLMK::setupFullscreen(UIView& videoView, const FloatRect& initialRect, const FloatSize& videoDimensions, UIView* parentView, HTMLMediaElementEnums::VideoFullscreenMode mode, bool allowsPictureInPicturePlayback, bool standby, bool blocksReturnToFullscreenFromPictureInPicture)
{
    linearMediaPlayer().contentDimensions = videoDimensions;
    VideoPresentationInterfaceIOS::setupFullscreen(videoView, initialRect, videoDimensions, parentView, mode, allowsPictureInPicturePlayback, standby, blocksReturnToFullscreenFromPictureInPicture);
}

void VideoPresentationInterfaceLMK::setupPlayerViewController()
{
    if (m_playerViewController)
        return;

    linearMediaPlayer().allowFullScreenFromInline = YES;
    linearMediaPlayer().contentType = WKSLinearMediaContentTypePlanar;
    linearMediaPlayer().presentationMode = WKSLinearMediaPresentationModeInline;
    linearMediaPlayer().captionLayer = captionsLayer();
    linearMediaPlayer().videoLayer = [m_playerLayerView playerLayer];

    m_playerViewController = [linearMediaPlayer() makeViewController];
}

void VideoPresentationInterfaceLMK::invalidatePlayerViewController()
{
    m_playerViewController = nil;
}

void VideoPresentationInterfaceLMK::presentFullscreen(bool animated, CompletionHandler<void(BOOL, NSError *)>&& completionHandler)
{
    linearMediaPlayer().presentationMode = WKSLinearMediaPresentationModeFullscreenFromInline;
    // FIXME: Wait until -linearMediaPlayer:didEnterFullscreenWithError: is called before calling completionHandler
    completionHandler(YES, nil);
}

void VideoPresentationInterfaceLMK::dismissFullscreen(bool animated, CompletionHandler<void(BOOL, NSError *)>&& completionHandler)
{
    linearMediaPlayer().presentationMode = WKSLinearMediaPresentationModeInline;
    // FIXME: Wait until -linearMediaPlayer:didExitFullscreenWithError: is called before calling completionHandler
    completionHandler(YES, nil);
}

UIViewController *VideoPresentationInterfaceLMK::playerViewController() const
{
    return m_playerViewController.get();
}

void VideoPresentationInterfaceLMK::setContentDimensions(const FloatSize& contentDimensions)
{
    linearMediaPlayer().contentDimensions = contentDimensions;
}

void VideoPresentationInterfaceLMK::setShowsPlaybackControls(bool showsPlaybackControls)
{
    linearMediaPlayer().showsPlaybackControls = showsPlaybackControls;
}

} // namespace WebKit

#endif // ENABLE(LINEAR_MEDIA_PLAYER)
