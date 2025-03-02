/*
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
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

#pragma once

#if ENABLE(MEDIA_SOURCE) && USE(AVFOUNDATION)

#include "MediaPlayerPrivate.h"
#include "SourceBufferPrivateClient.h"
#include "VideoFrameMetadata.h"
#include <CoreMedia/CMTime.h>
#include <wtf/Deque.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/LoggerHelper.h>
#include <wtf/MediaTime.h>
#include <wtf/RefCounted.h>
#include <wtf/WeakPtr.h>

OBJC_CLASS AVAsset;
OBJC_CLASS AVSampleBufferAudioRenderer;
OBJC_CLASS AVSampleBufferDisplayLayer;
OBJC_CLASS AVSampleBufferRenderSynchronizer;
OBJC_CLASS AVSampleBufferVideoRenderer;
OBJC_PROTOCOL(WebSampleBufferVideoRendering);

typedef struct OpaqueCMTimebase* CMTimebaseRef;
typedef struct __CVBuffer *CVPixelBufferRef;
typedef struct __CVBuffer *CVOpenGLTextureRef;
typedef struct OpaqueFigVideoTarget *FigVideoTargetRef;

namespace WebCore {

class AudioTrackPrivate;
class CDMSessionMediaSourceAVFObjC;
class EffectiveRateChangedListener;
class InbandTextTrackPrivate;
class MediaSourcePrivateAVFObjC;
class PixelBufferConformerCV;
class VideoLayerManagerObjC;
class VideoTrackPrivate;
class WebCoreDecompressionSession;


class MediaPlayerPrivateMediaSourceAVFObjC
    : public CanMakeWeakPtr<MediaPlayerPrivateMediaSourceAVFObjC>
    , public RefCounted<MediaPlayerPrivateMediaSourceAVFObjC>
    , public MediaPlayerPrivateInterface
    , private LoggerHelper
{
public:
    explicit MediaPlayerPrivateMediaSourceAVFObjC(MediaPlayer*);
    virtual ~MediaPlayerPrivateMediaSourceAVFObjC();

    void ref() final { RefCounted::ref(); }
    void deref() final { RefCounted::deref(); }

    static void registerMediaEngine(MediaEngineRegistrar);

    // MediaPlayer Factory Methods
    static bool isAvailable();
    static void getSupportedTypes(HashSet<String>& types);
    static MediaPlayer::SupportsType supportsTypeAndCodecs(const MediaEngineSupportParameters&);

ALLOW_NEW_API_WITHOUT_GUARDS_BEGIN
    void addAudioRenderer(AVSampleBufferAudioRenderer*);
    void removeAudioRenderer(AVSampleBufferAudioRenderer*);
ALLOW_NEW_API_WITHOUT_GUARDS_END
    
    void removeAudioTrack(AudioTrackPrivate&);
    void removeVideoTrack(VideoTrackPrivate&);
    void removeTextTrack(InbandTextTrackPrivate&);

    MediaPlayer::NetworkState networkState() const override;
    MediaPlayer::ReadyState readyState() const override;
    void setReadyState(MediaPlayer::ReadyState);
    void setNetworkState(MediaPlayer::NetworkState);

    void seekInternal();
    void maybeCompleteSeek();
    void setLoadingProgresssed(bool flag) { m_loadingProgressed = flag; }
    void setHasAvailableVideoFrame(bool);
    bool hasAvailableVideoFrame() const override;
ALLOW_NEW_API_WITHOUT_GUARDS_BEGIN
    void setHasAvailableAudioSample(AVSampleBufferAudioRenderer*, bool);
ALLOW_NEW_API_WITHOUT_GUARDS_END
    bool allRenderersHaveAvailableSamples() const { return m_allRenderersHaveAvailableSamples; }
    void updateAllRenderersHaveAvailableSamples();
    void durationChanged();

    void effectiveRateChanged();
    void sizeWillChangeAtTime(const MediaTime&, const FloatSize&);
    void setNaturalSize(const FloatSize&);
    void flushPendingSizeChanges();
    void characteristicsChanged();

    MediaTime currentTime() const override;
    bool currentTimeMayProgress() const override;
    AVSampleBufferDisplayLayer *sampleBufferDisplayLayer() const { return m_sampleBufferDisplayLayer.get(); }
    WebCoreDecompressionSession *decompressionSession() const { return m_decompressionSession.get(); }
    WebSampleBufferVideoRendering *sampleBufferVideoRenderer() const;

#if ENABLE(VIDEO_PRESENTATION_MODE)
    RetainPtr<PlatformLayer> createVideoFullscreenLayer() override;
    void setVideoFullscreenLayer(PlatformLayer*, Function<void()>&& completionHandler) override;
    void setVideoFullscreenFrame(FloatRect) override;
#endif

    bool requiresTextTrackRepresentation() const override;
    void setTextTrackRepresentation(TextTrackRepresentation*) override;
    void syncTextTrackBounds() override;
    
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    void setCDMSession(LegacyCDMSession*) override;
    CDMSessionMediaSourceAVFObjC* cdmSession() const;
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void cdmInstanceAttached(CDMInstance&) final;
    void cdmInstanceDetached(CDMInstance&) final;
    void attemptToDecryptWithInstance(CDMInstance&) final;
    bool waitingForKey() const final;
    void waitingForKeyChanged();
#endif

    void outputObscuredDueToInsufficientExternalProtectionChanged(bool);
    void beginSimulatedHDCPError() override { outputObscuredDueToInsufficientExternalProtectionChanged(true); }
    void endSimulatedHDCPError() override { outputObscuredDueToInsufficientExternalProtectionChanged(false); }

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    void keyNeeded(const SharedBuffer&);
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void initializationDataEncountered(const String&, RefPtr<ArrayBuffer>&&);
#endif

    const Vector<ContentType>& mediaContentTypesRequiringHardwareSupport() const;

    void needsVideoLayerChanged();

#if ENABLE(LINEAR_MEDIA_PLAYER)
    void setVideoReceiverEndpoint(const VideoReceiverEndpoint&) final;
#endif

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger.get(); }
    const char* logClassName() const override { return "MediaPlayerPrivateMediaSourceAVFObjC"; }
    const void* logIdentifier() const final { return reinterpret_cast<const void*>(m_logIdentifier); }
    WTFLogChannel& logChannel() const final;

    const void* mediaPlayerLogIdentifier() { return logIdentifier(); }
    const Logger& mediaPlayerLogger() { return logger(); }
#endif

    enum SeekState {
        Seeking,
        WaitingForAvailableFame,
        SeekCompleted,
    };

private:
    // MediaPlayerPrivateInterface
    void load(const String& url) override;
    void load(const URL&, const ContentType&, MediaSourcePrivateClient&) override;
#if ENABLE(MEDIA_STREAM)
    void load(MediaStreamPrivate&) override;
#endif
    void cancelLoad() override;

    void prepareToPlay() override;
    PlatformLayer* platformLayer() const override;

    bool supportsPictureInPicture() const override { return true; }
    bool supportsFullscreen() const override { return true; }

    void play() override;
    void playInternal(std::optional<MonotonicTime>&& = std::nullopt);

    void pause() override;
    void pauseInternal(std::optional<MonotonicTime>&& = std::nullopt);

    bool paused() const override;

    void setVolume(float volume) override;
    void setMuted(bool) override;

    bool supportsScanning() const override;

    FloatSize naturalSize() const override;

    bool hasVideo() const override;
    bool hasAudio() const override;

    void setPageIsVisible(bool, String&& sceneIdentifier) final;

    MediaTime duration() const override;
    MediaTime startTime() const override;
    MediaTime initialTime() const override;

    void seekToTarget(const SeekTarget&) final;
    bool seeking() const final;
    void setRateDouble(double) override;
    double rate() const override;
    double effectiveRate() const override;

    void setPreservesPitch(bool) override;

    MediaTime maxTimeSeekable() const override;
    MediaTime minTimeSeekable() const override;
    const PlatformTimeRanges& buffered() const override;

    bool didLoadingProgress() const override;

    RefPtr<NativeImage> nativeImageForCurrentTime() override;
    bool updateLastPixelBuffer();
    bool updateLastImage();
    void paint(GraphicsContext&, const FloatRect&) override;
    void paintCurrentFrameInContext(GraphicsContext&, const FloatRect&) override;
#if PLATFORM(COCOA) && !HAVE(AVSAMPLEBUFFERDISPLAYLAYER_COPYDISPLAYEDPIXELBUFFER)
    void willBeAskedToPaintGL() final;
#endif
    RefPtr<VideoFrame> videoFrameForCurrentTime() final;
    DestinationColorSpace colorSpace() final;

    bool supportsAcceleratedRendering() const override;
    // called when the rendering system flips the into or out of accelerated rendering mode.
    void acceleratedRenderingStateChanged() override;
    void notifyActiveSourceBuffersChanged() override;

    void setPresentationSize(const IntSize&) final;
    void setVideoLayerSizeFenced(const FloatSize&, WTF::MachSendRight&&) final;

    void updateDisplayLayerAndDecompressionSession();

    // NOTE: Because the only way for MSE to recieve data is through an ArrayBuffer provided by
    // javascript running in the page, the video will, by necessity, always be CORS correct and
    // in the page's origin.
    bool didPassCORSAccessCheck() const override { return true; }

    MediaPlayer::MovieLoadType movieLoadType() const override;

    void prepareForRendering() override;

    String engineDescription() const override;

    String languageOfPrimaryAudioTrack() const override;

    size_t extraMemoryCost() const override;

    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics() override;

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    bool isCurrentPlaybackTargetWireless() const override;
    void setWirelessPlaybackTarget(Ref<MediaPlaybackTarget>&&) override;
    void setShouldPlayToPlaybackTarget(bool) override;
    bool wirelessVideoPlaybackDisabled() const override { return false; }
#endif

    bool performTaskAtTime(Function<void()>&&, const MediaTime&) final;
    void audioOutputDeviceChanged() final;

    void ensureLayer();
    void destroyLayer();
    void ensureDecompressionSession();
    void destroyDecompressionSession();
    void ensureVideoRenderer();
    void destroyVideoRenderer();

    bool shouldBePlaying() const;

    bool setCurrentTimeDidChangeCallback(MediaPlayer::CurrentTimeDidChangeCallback&&) final;

    bool supportsPlayAtHostTime() const final { return true; }
    bool supportsPauseAtHostTime() const final { return true; }
    bool playAtHostTime(const MonotonicTime&) final;
    bool pauseAtHostTime(const MonotonicTime&) final;

    void startVideoFrameMetadataGathering() final;
    void stopVideoFrameMetadataGathering() final;
    std::optional<VideoFrameMetadata> videoFrameMetadata() final { return std::exchange(m_videoFrameMetadata, { }); }
    void setResourceOwner(const ProcessIdentity& resourceOwner) final { m_resourceOwner = resourceOwner; }

    void checkNewVideoFrameMetadata(CMTime);
    MediaTime clampTimeToLastSeekTime(const MediaTime&) const;

    bool shouldEnsureLayer() const;
    bool shouldEnsureVideoRenderer() const;

    void setShouldDisableHDR(bool) final;
    void playerContentBoxRectChanged(const LayoutRect&) final;
    void setShouldMaintainAspectRatio(bool) final;

#if HAVE(SPATIAL_TRACKING_LABEL)
    const String& spatialTrackingLabel() const final;
    void setSpatialTrackingLabel(String&&) final;
    void updateSpatialTrackingLabel();
#endif

    friend class MediaSourcePrivateAVFObjC;

    std::optional<SeekTarget> m_pendingSeek;

    ThreadSafeWeakPtr<MediaPlayer> m_player;
    WeakPtrFactory<MediaPlayerPrivateMediaSourceAVFObjC> m_sizeChangeObserverWeakPtrFactory;
    RefPtr<MediaSourcePrivateAVFObjC> m_mediaSourcePrivate;
    RetainPtr<AVAsset> m_asset;
    RetainPtr<AVSampleBufferDisplayLayer> m_sampleBufferDisplayLayer;
    RetainPtr<AVSampleBufferVideoRenderer> m_sampleBufferVideoRenderer;

    struct AudioRendererProperties {
        bool hasAudibleSample { false };
    };
ALLOW_NEW_API_WITHOUT_GUARDS_BEGIN
    HashMap<RetainPtr<CFTypeRef>, AudioRendererProperties> m_sampleBufferAudioRendererMap;
    RetainPtr<AVSampleBufferRenderSynchronizer> m_synchronizer;
ALLOW_NEW_API_WITHOUT_GUARDS_END
    mutable MediaPlayer::CurrentTimeDidChangeCallback m_currentTimeDidChangeCallback;
    RetainPtr<id> m_timeChangedObserver;
    RetainPtr<id> m_timeJumpedObserver;
    RetainPtr<id> m_durationObserver;
    RetainPtr<id> m_performTaskObserver;
    RetainPtr<CVPixelBufferRef> m_lastPixelBuffer;
    RefPtr<NativeImage> m_lastImage;
    std::unique_ptr<PixelBufferConformerCV> m_rgbConformer;
    RefPtr<WebCoreDecompressionSession> m_decompressionSession;
    Deque<RetainPtr<id>> m_sizeChangeObservers;
    Timer m_seekTimer;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    WeakPtr<CDMSessionMediaSourceAVFObjC> m_session;
#endif
    MediaPlayer::NetworkState m_networkState;
    MediaPlayer::ReadyState m_readyState;
    bool m_readyStateIsWaitingForAvailableFrame { false };
    MediaTime m_duration { MediaTime::invalidTime() };
    MediaTime m_lastSeekTime;
    FloatSize m_naturalSize;
    double m_rate { 1 };
    bool m_isPlaying { false };
    bool m_isSynchronizerSeeking { false };
    SeekState m_seekState { SeekCompleted };
    mutable bool m_loadingProgressed { false };
#if !HAVE(AVSAMPLEBUFFERDISPLAYLAYER_COPYDISPLAYEDPIXELBUFFER)
    bool m_hasBeenAskedToPaintGL { false };
#endif
    bool m_hasAvailableVideoFrame { false };
    bool m_allRenderersHaveAvailableSamples { false };
    bool m_visible { false };
    bool m_flushingActiveSourceBuffersDueToVisibilityChange { false };
    RetainPtr<CVOpenGLTextureRef> m_lastTexture;
#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    RefPtr<MediaPlaybackTarget> m_playbackTarget;
    bool m_shouldPlayToTarget { false };
#endif
    Ref<const Logger> m_logger;
    const void* m_logIdentifier;
    std::unique_ptr<VideoLayerManagerObjC> m_videoLayerManager;
    Ref<EffectiveRateChangedListener> m_effectiveRateChangedListener;
    uint64_t m_sampleCount { 0 };
    RetainPtr<id> m_videoFrameMetadataGatheringObserver;
    bool m_isGatheringVideoFrameMetadata { false };
    std::optional<VideoFrameMetadata> m_videoFrameMetadata;
    uint64_t m_lastConvertedSampleCount { 0 };
    ProcessIdentity m_resourceOwner;
    bool m_shouldMaintainAspectRatio { true };
#if HAVE(SPATIAL_TRACKING_LABEL)
    String m_spatialTrackingLabel;
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    RetainPtr<FigVideoTargetRef> m_videoTarget;
#endif
};

String convertEnumerationToString(MediaPlayerPrivateMediaSourceAVFObjC::SeekState);

}

namespace WTF {

template<typename Type>
struct LogArgument;

template <>
struct LogArgument<WebCore::MediaPlayerPrivateMediaSourceAVFObjC::SeekState> {
    static String toString(const WebCore::MediaPlayerPrivateMediaSourceAVFObjC::SeekState state)
    {
        return convertEnumerationToString(state);
    }
};

} // namespace WTF

#endif // ENABLE(MEDIA_SOURCE) && USE(AVFOUNDATION)
