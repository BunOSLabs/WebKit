/*
 * Copyright (C) 2010-2016 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "WK2BrowserWindowController.h"

#import "AppDelegate.h"
#import "SettingsController.h"
#import <QuartzCore/CATextLayer.h>
#import <SecurityInterface/SFCertificateTrustPanel.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WKFrameInfo.h>
#import <WebKit/WKNavigationActionPrivate.h>
#import <WebKit/WKNavigationDelegate.h>
#import <WebKit/WKOpenPanelParametersPrivate.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKUIDelegate.h>
#import <WebKit/WKUIDelegatePrivate.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebViewPrivateForTesting.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/WebNSURLExtras.h>
#import <WebKit/_WKIconLoadingDelegate.h>
#import <WebKit/_WKInspector.h>
#import <WebKit/_WKLinkIconParameters.h>
#import <WebKit/_WKUserInitiatedAction.h>

static void* keyValueObservingContext = &keyValueObservingContext;
static const int testHeaderBannerHeight = 42;
static const int testFooterBannerHeight = 58;

@interface MiniBrowserNSTextFinder : NSTextFinder

@property (nonatomic, copy) dispatch_block_t hideInterfaceCallback;

@end

@implementation MiniBrowserNSTextFinder

- (void)performAction:(NSTextFinderAction)op
{
    [super performAction:op];

    if (op == NSTextFinderActionHideFindInterface && _hideInterfaceCallback)
        _hideInterfaceCallback();
}

@end

@interface WK2BrowserWindowController () <NSTextFinderBarContainer, WKNavigationDelegate, WKUIDelegate, WKUIDelegatePrivate, _WKIconLoadingDelegate>
@end

@implementation WK2BrowserWindowController {
    WKWebViewConfiguration *_configuration;
    WKWebView *_webView;
    BOOL _zoomTextOnly;
    BOOL _isPrivateBrowsingWindow;

    BOOL _useShrinkToFit;

    MiniBrowserNSTextFinder *_textFinder;
    NSView *_textFindBarView;
    BOOL _findBarVisible;

    CATextLayer *_pointerLockBanner;
}

- (void)awakeFromNib
{
    _webView = [[WKWebView alloc] initWithFrame:[containerView bounds] configuration:_configuration];
    _webView.inspectable = YES;
    [self didChangeSettings];

    _webView.allowsMagnification = YES;
    _webView.allowsBackForwardNavigationGestures = YES;
    _webView._editable = self.isEditable;

    [_webView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [containerView addSubview:_webView];

    [progressIndicator bind:NSHiddenBinding toObject:_webView withKeyPath:@"loading" options:@{ NSValueTransformerNameBindingOption : NSNegateBooleanTransformerName }];
    [progressIndicator bind:NSValueBinding toObject:_webView withKeyPath:@"estimatedProgress" options:nil];

    [_webView addObserver:self forKeyPath:@"title" options:0 context:keyValueObservingContext];
    [_webView addObserver:self forKeyPath:@"URL" options:0 context:keyValueObservingContext];
    [_webView addObserver:self forKeyPath:@"hasOnlySecureContent" options:0 context:keyValueObservingContext];
    [_webView addObserver:self forKeyPath:@"_gpuProcessIdentifier" options:0 context:keyValueObservingContext];

    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;

    SettingsController *settingsController = [[NSApplication sharedApplication] browserAppDelegate].settingsController;
    // This setting installs the new WK2 Icon Loading Delegate and tests that mechanism by
    // telling WebKit to load every icon referenced by the page.
    if (settingsController.loadsAllSiteIcons)
        _webView._iconLoadingDelegate = self;
    
    _webView._observedRenderingProgressEvents = _WKRenderingProgressEventFirstLayout
        | _WKRenderingProgressEventFirstVisuallyNonEmptyLayout
        | _WKRenderingProgressEventFirstPaintWithSignificantArea
        | _WKRenderingProgressEventFirstLayoutAfterSuppressedIncrementalRendering
        | _WKRenderingProgressEventFirstPaintAfterSuppressedIncrementalRendering;


    if (settingsController.customUserAgent)
        _webView.customUserAgent = settingsController.customUserAgent;

    _webView._usePlatformFindUI = NO;

    _textFinder = [[MiniBrowserNSTextFinder alloc] init];
    _textFinder.incrementalSearchingEnabled = YES;
    _textFinder.incrementalSearchingShouldDimContentView = NO;
    _textFinder.client = _webView;
    _textFinder.findBarContainer = self;
    
#if __has_feature(objc_arc)
    __weak WKWebView *weakWebView = _webView;
#else
    WKWebView *weakWebView = _webView;
#endif
    _textFinder.hideInterfaceCallback = ^{
        WKWebView *webView = weakWebView;
        [webView _hideFindUI];
    };

    _zoomTextOnly = NO;
}

- (instancetype)initWithConfiguration:(WKWebViewConfiguration *)configuration
{
    if (!(self = [super initWithWindowNibName:@"BrowserWindow"]))
        return nil;

    _configuration = [configuration copy];
    _isPrivateBrowsingWindow = !_configuration.websiteDataStore.isPersistent;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userAgentDidChange:) name:kUserAgentChangedNotificationName object:nil];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_webView removeObserver:self forKeyPath:@"title"];
    [_webView removeObserver:self forKeyPath:@"URL"];
    [_webView removeObserver:self forKeyPath:@"hasOnlySecureContent"];
    [_webView removeObserver:self forKeyPath:@"_gpuProcessIdentifier"];
    
    [progressIndicator unbind:NSHiddenBinding];
    [progressIndicator unbind:NSValueBinding];
}

- (void)userAgentDidChange:(NSNotification *)notification
{
    SettingsController *settingsController = [[NSApplication sharedApplication] browserAppDelegate].settingsController;
    _webView.customUserAgent = settingsController.customUserAgent;
    [_webView reload];
}

- (IBAction)fetch:(id)sender
{
    [urlText setStringValue:[self addProtocolIfNecessary:urlText.stringValue]];
    NSURL *url = [NSURL _webkit_URLWithUserTypedString:urlText.stringValue];
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (IBAction)setPageScale:(id)sender
{
    CGFloat scale = [self pageScaleForMenuItemTag:[sender tag]];
    [_webView _setPageScale:scale withOrigin:CGPointZero];
}

- (CGFloat)viewScaleForMenuItemTag:(NSInteger)tag
{
    if (tag == 1)
        return 1;
    if (tag == 2)
        return 0.75;
    if (tag == 3)
        return 0.5;
    if (tag == 4)
        return 0.25;

    return 1;
}

- (IBAction)togglePictureInPicture:(id)sender
{
    [_webView _togglePictureInPicture];
}

- (IBAction)toggleInWindowFullscreen:(id)sender
{
    [_webView _toggleInWindow];
}

- (void)_webView:(WKWebView *)webView requestNotificationPermissionForSecurityOrigin:(WKSecurityOrigin *)securityOrigin decisionHandler:(void (^)(BOOL))decisionHandler
{
    NSDictionary *permissions = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NotificationPermissions"];
    NSString *originString = [NSString stringWithFormat:@"%@://%@", securityOrigin.protocol, securityOrigin.host];
    id value = [permissions valueForKey:originString];
    if (value) {
        decisionHandler([(NSNumber *)value boolValue]);
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];

    [alert setMessageText:[NSString stringWithFormat:@"Allow notification permissions for %@?", originString]];
    [alert addButtonWithTitle:@"Deny"];
    [alert addButtonWithTitle:@"Allow"];

    [alert beginSheetModalForWindow:self.window completionHandler:^void (NSModalResponse response) {
        BOOL granted = response == NSAlertSecondButtonReturn;

        NSMutableDictionary *permissions = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"NotificationPermissions"] mutableCopy];
        if (!permissions)
            permissions = [NSMutableDictionary dictionaryWithCapacity:1];
        [permissions setValue:@(granted) forKey:originString];
        [[NSUserDefaults standardUserDefaults] setObject:permissions forKey:@"NotificationPermissions"];

        decisionHandler(granted);
    }];
}

- (IBAction)setViewScale:(id)sender
{
    CGFloat scale = [self viewScaleForMenuItemTag:[sender tag]];
    CGFloat oldScale = [_webView _viewScale];

    if (scale == oldScale)
        return;

    [_webView _setLayoutMode:_WKLayoutModeDynamicSizeComputedFromViewScale];

    NSRect oldFrame = self.window.frame;
    NSSize newFrameSize = NSMakeSize(oldFrame.size.width * (scale / oldScale), oldFrame.size.height * (scale / oldScale));
    [self.window setFrame:NSMakeRect(oldFrame.origin.x, oldFrame.origin.y - (newFrameSize.height - oldFrame.size.height), newFrameSize.width, newFrameSize.height) display:NO animate:NO];

    [_webView _setViewScale:scale];
}

static BOOL areEssentiallyEqual(double a, double b)
{
    double tolerance = 0.001;
    return (fabs(a - b) <= tolerance);
}

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
#pragma GCC diagnostic pop
{
    SEL action = menuItem.action;

    if (action == @selector(saveAsPDF:))
        return YES;
    if (action == @selector(saveAsImage:))
        return YES;
    if (action == @selector(saveAsWebArchive:))
        return YES;

    if (action == @selector(zoomIn:))
        return [self canZoomIn];
    if (action == @selector(zoomOut:))
        return [self canZoomOut];
    if (action == @selector(resetZoom:))
        return [self canResetZoom];
    
    // Disabled until missing WK2 functionality is exposed via API/SPI.
    if (action == @selector(dumpSourceToConsole:)
        || action == @selector(forceRepaint:))
        return NO;
    
    if (action == @selector(showHideWebView:))
        [menuItem setTitle:[_webView isHidden] ? @"Show Web View" : @"Hide Web View"];
    else if (action == @selector(removeReinsertWebView:))
        [menuItem setTitle:[_webView window] ? @"Remove Web View" : @"Insert Web View"];
    else if (action == @selector(toggleFullWindowWebView:))
        [menuItem setTitle:[self webViewFillsWindow] ? @"Inset Web View" : @"Fit Web View to Window"];
    else if (action == @selector(toggleZoomMode:))
        [menuItem setState:_zoomTextOnly ? NSControlStateValueOn : NSControlStateValueOff];
    else if (action == @selector(toggleEditable:))
        [menuItem setState:self.isEditable ? NSControlStateValueOn : NSControlStateValueOff];
    else if (action == @selector(showHideWebInspector:))
        [menuItem setTitle:_webView._inspector.isVisible ? @"Close Web Inspector" : @"Show Web Inspector"];
    else if (action == @selector(toggleAlwaysShowsHorizontalScroller:))
        menuItem.state = _webView._alwaysShowsHorizontalScroller ? NSControlStateValueOn : NSControlStateValueOff;
    else if (action == @selector(toggleAlwaysShowsVerticalScroller:))
        menuItem.state = _webView._alwaysShowsVerticalScroller ? NSControlStateValueOn : NSControlStateValueOff;
    else if (action == @selector(toggleMainThreadStalls:))
        menuItem.state = self.mainThreadStallsEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    [_webView _updateMediaPlaybackControlsManager];
    if (action == @selector(togglePictureInPicture:)) {
        menuItem.state = _webView._isPictureInPictureActive ? NSControlStateValueOn : NSControlStateValueOff;
        return _webView._canTogglePictureInPicture;
    }

    if (action == @selector(toggleInWindowFullscreen:)) {
        menuItem.state = _webView._isInWindowActive ? NSControlStateValueOn : NSControlStateValueOff;
        return _webView._canToggleInWindow;
    }

    if (action == @selector(setPageScale:))
        [menuItem setState:areEssentiallyEqual([_webView _pageScale], [self pageScaleForMenuItemTag:[menuItem tag]])];

    if (action == @selector(setViewScale:))
        [menuItem setState:areEssentiallyEqual([_webView _viewScale], [self viewScaleForMenuItemTag:[menuItem tag]])];

    return YES;
}

- (IBAction)reload:(id)sender
{
    [_webView reload];
}

- (IBAction)showCertificate:(id)sender
{
    if (_webView.serverTrust)
        [[SFCertificateTrustPanel sharedCertificateTrustPanel] beginSheetForWindow:self.window modalDelegate:nil didEndSelector:nil contextInfo:NULL trust:_webView.serverTrust message:@"TLS Certificate Details"];
}

- (IBAction)logAccessibilityTrees:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[ @"axtree" ];
#pragma clang diagnostic pop
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [self->_webView _retrieveAccessibilityTreeData:^(NSData *data, NSError *error) {
                [data writeToURL:[panel URL] options:0 error:nil];
            }];
        }
    }];
}

- (IBAction)forceRepaint:(id)sender
{
    // FIXME: This doesn't actually force a repaint.
    [_webView setNeedsDisplay:YES];
}

- (IBAction)goBack:(id)sender
{
    [_webView goBack];
}

- (IBAction)goForward:(id)sender
{
    [_webView goForward];
}

- (IBAction)toggleZoomMode:(id)sender
{
    if (_zoomTextOnly) {
        _zoomTextOnly = NO;
        double currentTextZoom = _webView._textZoomFactor;
        _webView._textZoomFactor = 1;
        _webView.pageZoom = currentTextZoom;
    } else {
        _zoomTextOnly = YES;
        double currentPageZoom = _webView._pageZoomFactor;
        _webView._textZoomFactor = currentPageZoom;
        _webView.pageZoom = 1;
    }
}

- (IBAction)resetZoom:(id)sender
{
    if (![self canResetZoom])
        return;

    if (_zoomTextOnly)
        _webView._textZoomFactor = 1;
    else {
        _webView.pageZoom = 1;
        _webView.magnification = 1;
    }
}

- (BOOL)canResetZoom
{
    return _zoomTextOnly ? (_webView._textZoomFactor != 1) : (_webView.pageZoom != 1);
}

- (IBAction)toggleShrinkToFit:(id)sender
{
    _useShrinkToFit = !_useShrinkToFit;
    toggleUseShrinkToFitButton.image = _useShrinkToFit ? [NSImage imageNamed:@"NSExitFullScreenTemplate"] : [NSImage imageNamed:@"NSEnterFullScreenTemplate"];
    [_webView _setLayoutMode:_useShrinkToFit ? _WKLayoutModeDynamicSizeComputedFromMinimumDocumentSize : _WKLayoutModeViewSize];
}

- (IBAction)dumpSourceToConsole:(id)sender
{
}

- (IBAction)showHideWebInspector:(id)sender
{
    _WKInspector *inspector = _webView._inspector;
    if (inspector.isVisible)
        [inspector hide];
    else
        [inspector show];
}

- (IBAction)toggleAlwaysShowsHorizontalScroller:(id)sender
{
    _webView._alwaysShowsHorizontalScroller = !_webView._alwaysShowsHorizontalScroller;
}

- (IBAction)toggleAlwaysShowsVerticalScroller:(id)sender
{
    _webView._alwaysShowsVerticalScroller = !_webView._alwaysShowsVerticalScroller;
}

- (NSURL *)currentURL
{
    return _webView.URL;
}

- (NSView *)mainContentView
{
    return _webView;
}

- (void)setEditable:(BOOL)editable
{
    [super setEditable:editable];
    _webView._editable = editable;
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item
{
    SEL action = item.action;

    if (action == @selector(goBack:) || action == @selector(goForward:))
        return [_webView validateUserInterfaceItem:item];

    if (action == @selector(showCertificate:))
        return _webView.serverTrust != nil;

    return YES;
}

- (void)validateToolbar
{
    [toolbar validateVisibleItems];
}

- (BOOL)windowShouldClose:(id)sender
{
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification
{
    [[[NSApplication sharedApplication] browserAppDelegate] browserWindowWillClose:self.window];
}

#define DefaultMinimumZoomFactor (.5)
#define DefaultMaximumZoomFactor (3.0)
#define DefaultZoomFactorRatio (1.2)

- (CGFloat)currentZoomFactor
{
    return _zoomTextOnly ? _webView._textZoomFactor : _webView.pageZoom;
}

- (void)setCurrentZoomFactor:(CGFloat)factor
{
    if (_zoomTextOnly)
        _webView._textZoomFactor = factor;
    else
        _webView.pageZoom = factor;
}

- (BOOL)canZoomIn
{
    return self.currentZoomFactor * DefaultZoomFactorRatio < DefaultMaximumZoomFactor;
}

- (void)zoomIn:(id)sender
{
    if (!self.canZoomIn)
        return;

    self.currentZoomFactor *= DefaultZoomFactorRatio;
}

- (BOOL)canZoomOut
{
    return self.currentZoomFactor / DefaultZoomFactorRatio > DefaultMinimumZoomFactor;
}

- (void)zoomOut:(id)sender
{
    if (!self.canZoomIn)
        return;

    self.currentZoomFactor /= DefaultZoomFactorRatio;
}

- (void)didChangeSettings
{
    SettingsController *settings = [[NSApplication sharedApplication] browserAppDelegate].settingsController;
    WKPreferences *preferences = _webView.configuration.preferences;

    _webView._useSystemAppearance = settings.useSystemAppearance;

    preferences._tiledScrollingIndicatorVisible = settings.tiledScrollingIndicatorVisible;
    preferences._compositingBordersVisible = settings.layerBordersVisible;
    preferences._compositingRepaintCountersVisible = settings.layerBordersVisible;
    preferences._legacyLineLayoutVisualCoverageEnabled = settings.legacyLineLayoutVisualCoverageEnabled;
    preferences._acceleratedDrawingEnabled = settings.acceleratedDrawingEnabled;
    preferences._resourceUsageOverlayVisible = settings.resourceUsageOverlayVisible;
    preferences._largeImageAsyncDecodingEnabled = settings.largeImageAsyncDecodingEnabled;
    preferences._animatedImageAsyncDecodingEnabled = settings.animatedImageAsyncDecodingEnabled;
    preferences._colorFilterEnabled = settings.appleColorFilterEnabled;
    preferences._punchOutWhiteBackgroundsInDarkMode = settings.punchOutWhiteBackgroundsInDarkMode;
    preferences._mockCaptureDevicesEnabled = settings.useMockCaptureDevices;

    preferences._serviceControlsEnabled = settings.dataDetectorsEnabled;
    preferences._telephoneNumberDetectionIsEnabled = settings.dataDetectorsEnabled;

    _webView.configuration.websiteDataStore._resourceLoadStatisticsEnabled = settings.resourceLoadStatisticsEnabled;

    [self setWebViewFillsWindow:settings.webViewFillsWindow];

    BOOL useTransparentWindows = settings.useTransparentWindows;
    if (useTransparentWindows != !_webView._drawsBackground) {
        [self.window setOpaque:!useTransparentWindows];
        [self.window setBackgroundColor:[NSColor clearColor]];
        [self.window setHasShadow:!useTransparentWindows];

        _webView._drawsBackground = !useTransparentWindows;

        [self.window display];
    }

    BOOL usePaginatedMode = settings.usePaginatedMode;
    if (usePaginatedMode != (_webView._paginationMode != _WKPaginationModeUnpaginated)) {
        if (usePaginatedMode) {
            _webView._paginationMode = _WKPaginationModeLeftToRight;
            _webView._pageLength = _webView.bounds.size.width / 2;
            _webView._gapBetweenPages = 10;
        } else
            _webView._paginationMode = _WKPaginationModeUnpaginated;
    }
    
    NSUInteger visibleOverlayRegions = 0;
    if (settings.nonFastScrollableRegionOverlayVisible)
        visibleOverlayRegions |= _WKNonFastScrollableRegion;
    if (settings.wheelEventHandlerRegionOverlayVisible)
        visibleOverlayRegions |= _WKWheelEventHandlerRegion;
    if (settings.interactionRegionOverlayVisible)
        visibleOverlayRegions |= _WKInteractionRegion;
    
    preferences._visibleDebugOverlayRegions = visibleOverlayRegions;

    int headerBannerHeight = [settings isSpaceReservedForBanners] ? testHeaderBannerHeight : 0;
    if (!headerBannerHeight)
        [_webView _setHeaderBannerLayer:nil];
    else {
        CALayer *headerBannerLayer = [[CALayer alloc] init];
        [headerBannerLayer setBounds:CGRectMake(0, 0, 0, headerBannerHeight)];
        [headerBannerLayer setAnchorPoint:CGPointZero];
        [headerBannerLayer setBackgroundColor:[NSColor colorWithSRGBRed:172. / 255. green:221 / 255. blue:222. / 255. alpha:1].CGColor];
        [_webView _setHeaderBannerLayer:headerBannerLayer];
    }

    int footerBannerHeight = [settings isSpaceReservedForBanners] ? testFooterBannerHeight : 0;
    if (!footerBannerHeight)
        [_webView _setFooterBannerLayer:nil];
    else {
        CALayer *footerBannerLayer = [[CALayer alloc] init];
        [footerBannerLayer setBounds:CGRectMake(0, 0, 0, footerBannerHeight)];
        [footerBannerLayer setAnchorPoint:CGPointZero];
        [footerBannerLayer setBackgroundColor:[NSColor colorWithSRGBRed:116. / 255. green:187. / 255. blue:251. / 255. alpha:1].CGColor];
        [_webView _setFooterBannerLayer:footerBannerLayer];
    }
}

- (void)updateTitleForBadgeChange
{
    [self updateTitle:_webView.title];
}

- (void)updateTitle:(NSString *)title
{
    if (!title.length) {
        NSURL *url = _webView.URL;
        title = url.lastPathComponent ?: url._web_userVisibleString;
    }

    if (!title.length)
        title = @"MiniBrowser";

    if (BrowserAppDelegate.currentBadge)
        title = [title stringByAppendingFormat:@" (%@)", BrowserAppDelegate.currentBadge];

    self.window.title = title;

    NSMutableString *subtitle = [@"[WK2" mutableCopy];
    __auto_type appendProcessIdentifier = ^(NSString *name, pid_t processIdentifier) {
        if (!processIdentifier)
            return;
        [subtitle appendFormat:@" %@:%d", name, processIdentifier];
    };

    appendProcessIdentifier(@"web", _webView._webProcessIdentifier);
    appendProcessIdentifier(@"net", _webView.configuration.websiteDataStore._networkProcessIdentifier);
    appendProcessIdentifier(@"gpu", _webView._gpuProcessIdentifier);

    [subtitle appendString:@"]"];

    if (_isPrivateBrowsingWindow)
        [subtitle appendString:@" 🙈"];

    if (_webView._editable)
        [subtitle appendString:@" ✏️"];

    self.window.subtitle = subtitle;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != keyValueObservingContext || object != _webView)
        return;

    if ([keyPath isEqualToString:@"title"])
        [self updateTitle:_webView.title];
    else if ([keyPath isEqualToString:@"URL"])
        [self updateTextFieldFromURL:_webView.URL];
    else if ([keyPath isEqualToString:@"hasOnlySecureContent"])
        [self updateLockButtonIcon:_webView.hasOnlySecureContent];
    else if ([keyPath isEqualToString:@"_gpuProcessIdentifier"])
        [self updateTitle:_webView.title];
}

- (nullable WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    WK2BrowserWindowController *controller = [[WK2BrowserWindowController alloc] initWithConfiguration:configuration];
    [controller awakeFromNib];
    [controller.window makeKeyAndOrderFront:self];
    
    [[[NSApplication sharedApplication] browserAppDelegate] didCreateBrowserWindowController:controller];

    return controller->_webView;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
    NSAlert* alert = [[NSAlert alloc] init];

    [alert setMessageText:[NSString stringWithFormat:@"JavaScript alert dialog from %@.", [frame.request.URL absoluteString]]];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:@"OK"];

    [alert beginSheetModalForWindow:self.window completionHandler:^void (NSModalResponse response) {
        completionHandler();
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler
{
    NSAlert* alert = [[NSAlert alloc] init];

    [alert setMessageText:[NSString stringWithFormat:@"JavaScript confirm dialog from %@.", [frame.request.URL  absoluteString]]];
    [alert setInformativeText:message];
    
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.window completionHandler:^void (NSModalResponse response) {
        completionHandler(response == NSAlertFirstButtonReturn);
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *result))completionHandler
{
    NSAlert* alert = [[NSAlert alloc] init];

    [alert setMessageText:[NSString stringWithFormat:@"JavaScript prompt dialog from %@.", [frame.request.URL absoluteString]]];
    [alert setInformativeText:prompt];
    
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [input setStringValue:defaultText];
    [alert setAccessoryView:input];
    
    [alert beginSheetModalForWindow:self.window completionHandler:^void (NSModalResponse response) {
        [input validateEditing];
        completionHandler(response == NSAlertFirstButtonReturn ? [input stringValue] : nil);
    }];
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> * URLs))completionHandler
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];

    openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [openPanel setAllowedFileTypes:parameters._allowedFileExtensions];
#pragma clang diagnostic pop

    [openPanel beginSheetModalForWindow:webView.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK)
            completionHandler(openPanel.URLs);
        else
            completionHandler(nil);
    }];
}

- (void)_webView:(WebView *)sender runBeforeUnloadConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler
{
    NSAlert *alert = [[NSAlert alloc] init];

    alert.messageText = [NSString stringWithFormat:@"JavaScript before unload dialog from %@.", [frame.request.URL absoluteString]];
    alert.informativeText = message;

    [alert addButtonWithTitle:@"Leave Page"];
    [alert addButtonWithTitle:@"Stay On Page"];

    [alert beginSheetModalForWindow:self.window completionHandler:^void (NSModalResponse response) {
        completionHandler(response == NSAlertFirstButtonReturn);
    }];
}

- (WKDragDestinationAction)_webView:(WKWebView *)webView dragDestinationActionMaskForDraggingInfo:(id)draggingInfo
{
    return WKDragDestinationActionAny;
}

- (void)_webView:(WKWebView *)webView printFrame:(_WKFrameHandle *)frame pdfFirstPageSize:(CGSize)size completionHandler:(void (^)(void))completionHandler
{
    [[_webView printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]] runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
    completionHandler();
}

- (void)updateTextFieldFromURL:(NSURL *)URL
{
    if (!URL)
        return;

    if (!URL.absoluteString.length)
        return;

    urlText.stringValue = [URL _web_userVisibleString];
}

- (void)updateLockButtonIcon:(BOOL)hasOnlySecureContent
{
    if (hasOnlySecureContent)
        [lockButton setImage:[NSImage imageWithSystemSymbolName:@"lock" accessibilityDescription:nil]];
    else
        [lockButton setImage:[NSImage imageWithSystemSymbolName:@"lock.open" accessibilityDescription:nil]];
}

- (void)loadURLString:(NSString *)urlString
{
    // FIXME: We shouldn't have to set the url text here.
    [urlText setStringValue:urlString];
    [self fetch:nil];
}

- (void)loadHTMLString:(NSString *)HTMLString
{
    [_webView loadHTMLString:HTMLString baseURL:nil];
}

static NSSet *dataTypes(void)
{
    return [WKWebsiteDataStore allWebsiteDataTypes];
}

- (IBAction)fetchWebsiteData:(id)sender
{
    [_configuration.websiteDataStore _fetchDataRecordsOfTypes:dataTypes() withOptions:_WKWebsiteDataStoreFetchOptionComputeSizes completionHandler:^(NSArray *websiteDataRecords) {
        NSLog(@"did fetch website data %@.", websiteDataRecords);
    }];
}

- (IBAction)fetchAndClearWebsiteData:(id)sender
{
    [_configuration.websiteDataStore fetchDataRecordsOfTypes:dataTypes() completionHandler:^(NSArray *websiteDataRecords) {
        [self->_configuration.websiteDataStore removeDataOfTypes:dataTypes() forDataRecords:websiteDataRecords completionHandler:^{
            [self->_configuration.websiteDataStore fetchDataRecordsOfTypes:dataTypes() completionHandler:^(NSArray *websiteDataRecords) {
                NSLog(@"did clear website data, after clearing data is %@.", websiteDataRecords);
            }];
        }];
    }];
}

- (IBAction)clearWebsiteData:(id)sender
{
    [_configuration.websiteDataStore removeDataOfTypes:dataTypes() modifiedSince:[NSDate distantPast] completionHandler:^{
        NSLog(@"Did clear website data.");
    }];
}

- (IBAction)printWebView:(id)sender
{
    [[_webView printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]] runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
}

static BOOL isJavaScriptURL(NSURL *url)
{
    return [url.scheme isEqualToString:@"javascript"];
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    LOG(@"decidePolicyForNavigationAction");

    if (navigationAction._canHandleRequest) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    NSURL *url = navigationAction.request.URL;
    
    if (!isJavaScriptURL(url) && navigationAction._userInitiatedAction && !navigationAction._userInitiatedAction.isConsumed) {
        [navigationAction._userInitiatedAction consume];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }

    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    LOG(@"decidePolicyForNavigationResponse");
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    LOG(@"didStartProvisionalNavigation: %@", navigation);
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation
{
    LOG(@"didReceiveServerRedirectForProvisionalNavigation: %@", navigation);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    LOG(@"didFailProvisionalNavigation: %@navigation, error: %@", navigation, error);
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    LOG(@"didCommitNavigation: %@", navigation);
    [self updateTitle:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    LOG(@"didFinishNavigation: %@", navigation);
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *__nullable credential))completionHandler
{
    LOG(@"didReceiveAuthenticationChallenge: %@", challenge);
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]) {
        NSAlert *alert = [[NSAlert alloc] init];
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 48)];
        NSTextField *userInput = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 24, 200, 24)];
        NSTextField *passwordInput = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        
        [alert setMessageText:[NSString stringWithFormat:@"Log in to %@:%lu.", challenge.protectionSpace.host, challenge.protectionSpace.port]];
        [alert addButtonWithTitle:@"Log in"];
        [alert addButtonWithTitle:@"Cancel"];
        [container addSubview:userInput];
        [container addSubview:passwordInput];
        [alert setAccessoryView:container];
        [userInput setNextKeyView:passwordInput];
        [alert.window setInitialFirstResponder:userInput];
        
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            [userInput validateEditing];
            if (response == NSAlertFirstButtonReturn)
                completionHandler(NSURLSessionAuthChallengeUseCredential, [[NSURLCredential alloc] initWithUser:[userInput stringValue] password:[passwordInput stringValue] persistence:NSURLCredentialPersistenceForSession]);
            else
                completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        }];
        return;
    }
    completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    LOG(@"didFailNavigation: %@, error %@", navigation, error);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    NSLog(@"WebContent process crashed; reloading");
    [self reload:nil];
}

- (void)_webView:(WKWebView *)webView renderingProgressDidChange:(_WKRenderingProgressEvents)progressEvents
{
    if (progressEvents & _WKRenderingProgressEventFirstLayout)
        LOG(@"renderingProgressDidChange: %@", @"first layout");

    if (progressEvents & _WKRenderingProgressEventFirstVisuallyNonEmptyLayout)
        LOG(@"renderingProgressDidChange: %@", @"first visually non-empty layout");

    if (progressEvents & _WKRenderingProgressEventFirstPaintWithSignificantArea)
        LOG(@"renderingProgressDidChange: %@", @"first paint with significant area");

    if (progressEvents & _WKRenderingProgressEventFirstLayoutAfterSuppressedIncrementalRendering)
        LOG(@"renderingProgressDidChange: %@", @"first layout after suppressed incremental rendering");

    if (progressEvents & _WKRenderingProgressEventFirstPaintAfterSuppressedIncrementalRendering)
        LOG(@"renderingProgressDidChange: %@", @"first paint after suppressed incremental rendering");
}

- (void)webView:(WKWebView *)webView shouldLoadIconWithParameters:(_WKLinkIconParameters *)parameters completionHandler:(void (^)(void (^)(NSData*)))completionHandler
{
    completionHandler(^void (NSData *data) {
        LOG(@"Icon URL %@ received icon data of length %u", parameters.url, (unsigned)data.length);
    });
}

#pragma mark Find in Page

- (IBAction)performTextFinderAction:(id)sender
{
    [_textFinder performAction:[sender tag]];
}

- (NSView *)findBarView
{
    return _textFindBarView;
}

- (void)setFindBarView:(NSView *)findBarView
{
    _textFindBarView = findBarView;
    _textFindBarView.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;
    _textFindBarView.frame = NSMakeRect(0, 0, containerView.bounds.size.width, _textFindBarView.frame.size.height);

    _findBarVisible = YES;
}

- (BOOL)isFindBarVisible
{
    return _findBarVisible;
}

- (void)setFindBarVisible:(BOOL)findBarVisible
{
    _findBarVisible = findBarVisible;
    if (findBarVisible)
        [containerView addSubview:_textFindBarView];
    else
        [_textFindBarView removeFromSuperview];
}

- (NSView *)contentView
{
    return _webView;
}

- (void)findBarViewDidChangeHeight
{
}

- (IBAction)saveAsPDF:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ UTTypePDF ];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK)
            return;
        [self->_webView createPDFWithConfiguration:nil completionHandler:^(NSData *pdfSnapshotData, NSError *error) {
            [pdfSnapshotData writeToURL:[panel URL] options:0 error:nil];
        }];
    }];
}

- (IBAction)saveAsImage:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ UTTypeTIFF ];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK)
            return;
        [self->_webView takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *snapshot, NSError *error) {
            [snapshot.TIFFRepresentation writeToURL:[panel URL] options:0 error:nil];
        }];
    }];
}

- (IBAction)saveAsWebArchive:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ UTTypeWebArchive ];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK)
            return;
        [self->_webView createWebArchiveDataWithCompletionHandler:^(NSData *archiveData, NSError *error) {
            [archiveData writeToURL:[panel URL] options:0 error:nil];
        }];
    }];
}

- (void)_webViewDidRequestPointerLock:(WKWebView *)webView completionHandler:(void (^)(BOOL))completionHandler
{
    if (!_pointerLockBanner) {
        _pointerLockBanner = [[CATextLayer alloc] init];
        [_pointerLockBanner setString:[[NSAttributedString alloc] initWithString:@"Your mouse pointer is hidden. Press Esc (Escape) once to reveal your mouse pointer." attributes:@{ NSFontAttributeName:[NSFont systemFontOfSize:16], NSForegroundColorAttributeName:NSColor.blackColor }]];
        [_pointerLockBanner setBackgroundColor:NSColor.lightGrayColor.CGColor];
        [_pointerLockBanner setWrapped:YES];
        [_pointerLockBanner setFrame:CGRectMake(0, 0, 0, testHeaderBannerHeight)];
        [_pointerLockBanner setContentsScale:[NSScreen mainScreen].backingScaleFactor];
    }
    [webView _setHeaderBannerLayer:_pointerLockBanner];
    completionHandler(YES);
}

- (void)_webViewDidLosePointerLock:(WKWebView *)webView
{
    [webView _setHeaderBannerLayer:nil];
}

@end
