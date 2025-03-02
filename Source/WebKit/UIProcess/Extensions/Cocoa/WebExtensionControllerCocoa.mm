/*
 * Copyright (C) 2022-2024 Apple Inc. All rights reserved.
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

#if !__has_feature(objc_arc)
#error This file requires ARC. Add the "-fobjc-arc" compiler flag for this file.
#endif

#import "config.h"
#import "WebExtensionController.h"

#if ENABLE(WK_WEB_EXTENSIONS)

#import "CocoaHelpers.h"
#import "ContextMenuContextData.h"
#import "Logging.h"
#import "SandboxUtilities.h"
#import "WKWebViewConfigurationPrivate.h"
#import "WKWebsiteDataStoreInternal.h"
#import "WebExtensionContext.h"
#import "WebExtensionContextMessages.h"
#import "WebExtensionContextParameters.h"
#import "WebExtensionContextProxyMessages.h"
#import "WebExtensionControllerMessages.h"
#import "WebExtensionControllerProxyMessages.h"
#import "WebExtensionDataRecord.h"
#import "WebExtensionEventListenerType.h"
#import "WebPageProxy.h"
#import "WebProcessPool.h"
#import "_WKWebExtensionStorageSQLiteStore.h"
#import <WebCore/ContentRuleListResults.h>
#import <wtf/BlockPtr.h>
#import <wtf/CallbackAggregator.h>
#import <wtf/FileSystem.h>
#import <wtf/HashMap.h>
#import <wtf/HashSet.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/text/WTFString.h>

static constexpr Seconds purgeMatchedRulesInterval = 5_min;

namespace WebKit {

String WebExtensionController::storageDirectory(WebExtensionContext& extensionContext) const
{
    if (m_configuration->storageIsPersistent() && extensionContext.hasCustomUniqueIdentifier())
        return FileSystem::pathByAppendingComponent(m_configuration->storageDirectory(), extensionContext.uniqueIdentifier());
    return nullString();
}

void WebExtensionController::getDataRecords(OptionSet<WebExtensionDataType> types, CompletionHandler<void(Vector<Ref<WebExtensionDataRecord>>)>&& completionHandler)
{
    if (!m_configuration->storageIsPersistent() || types.isEmpty()) {
        completionHandler({ });
        return;
    }

    auto recordHolder = WebExtensionDataRecordHolder::create();
    auto aggregator = MainRunLoopCallbackAggregator::create([recordHolder, completionHandler = WTFMove(completionHandler)]() mutable {
        Vector<Ref<WebExtensionDataRecord>> records;
        for (auto& entry : recordHolder->recordsMap)
            records.append(entry.value);

        completionHandler(records);
    });

    auto uniqueIdentifiers = FileSystem::listDirectory(m_configuration->storageDirectory());
    for (auto& uniqueIdentifier : uniqueIdentifiers) {
        String displayName;
        URL lastBaseURL;
        if (!WebExtensionContext::readDisplayNameAndLastBaseURLFromState(stateFilePath(uniqueIdentifier), displayName, lastBaseURL))
            continue;

        for (auto type : types) {
            auto *storage = sqliteStore(storageDirectory(uniqueIdentifier), type, this->extensionContext(lastBaseURL));
            if (!storage)
                continue;

            calculateStorageSize(storage, type, makeBlockPtr([recordHolder, aggregator, uniqueIdentifier, displayName, type](size_t size) mutable {
                Ref record = recordHolder->recordsMap.ensure(uniqueIdentifier, [&] {
                    return WebExtensionDataRecord::create(displayName, uniqueIdentifier);
                }).iterator->value;
                record->setSizeOfType(type, size);
            }));
        }
    }
}

void WebExtensionController::getDataRecord(OptionSet<WebExtensionDataType> types, WebExtensionContext& extensionContext, CompletionHandler<void(RefPtr<WebExtensionDataRecord>)>&& completionHandler)
{
    if (!m_configuration->storageIsPersistent() || types.isEmpty()) {
        completionHandler(nullptr);
        return;
    }

    String matchingUniqueIdentifier;
    String displayName;
    URL lastBaseURL;

    auto recordHolder = WebExtensionDataRecordHolder::create();
    auto aggregator = MainRunLoopCallbackAggregator::create([recordHolder, completionHandler = WTFMove(completionHandler)]() mutable {
        completionHandler(recordHolder->recordsMap.takeFirst());
    });

    auto uniqueIdentifiers = FileSystem::listDirectory(m_configuration->storageDirectory());
    for (auto& uniqueIdentifier : uniqueIdentifiers) {
        if (!WebExtensionContext::readDisplayNameAndLastBaseURLFromState(stateFilePath(uniqueIdentifier), displayName, lastBaseURL))
            continue;

        if (this->extensionContext(lastBaseURL)->extension() == extensionContext.extension()) {
            matchingUniqueIdentifier = uniqueIdentifier;
            break;
        }
    }

    if (!matchingUniqueIdentifier) {
        completionHandler(nullptr);
        return;
    }

    for (auto type : types) {
        auto *storage = sqliteStore(storageDirectory(matchingUniqueIdentifier), type, this->extensionContext(lastBaseURL));
        if (!storage)
            continue;

        calculateStorageSize(storage, type, makeBlockPtr([recordHolder, aggregator, matchingUniqueIdentifier, displayName, type](size_t size) mutable {
            Ref record = recordHolder->recordsMap.ensure(matchingUniqueIdentifier, [&] {
                return WebExtensionDataRecord::create(displayName, matchingUniqueIdentifier);
            }).iterator->value;
            record->setSizeOfType(type, size);
        }));
    }
}

void WebExtensionController::removeData(OptionSet<WebExtensionDataType> types, const Vector<Ref<WebExtensionDataRecord>>& records, CompletionHandler<void()>&& completionHandler)
{
    if (!m_configuration->storageIsPersistent() || types.isEmpty() || records.isEmpty()) {
        completionHandler();
        return;
    }

    auto aggregator = MainRunLoopCallbackAggregator::create([completionHandler = WTFMove(completionHandler)]() mutable {
        completionHandler();
    });

    for (auto& record : records) {
        URL lastBaseURL;
        auto uniqueIdentifier = record.get().uniqueIdentifier();
        if (!WebExtensionContext::readLastBaseURLFromState(stateFilePath(uniqueIdentifier), lastBaseURL))
            continue;

        for (auto type : types) {
            auto *storage = sqliteStore(storageDirectory(uniqueIdentifier), type, this->extensionContext(lastBaseURL));
            if (!storage)
                continue;

            removeStorage(storage, type, makeBlockPtr([aggregator]() mutable { }));
        }
    }
}

void WebExtensionController::calculateStorageSize(_WKWebExtensionStorageSQLiteStore *storage, WebExtensionDataType type, CompletionHandler<void(size_t)>&& completionHandler)
{
    [storage getStorageSizeForKeys:@[ ] completionHandler:makeBlockPtr([completionHandler = WTFMove(completionHandler)](size_t storageSize, NSString *errorMessage) mutable {
        // FIXME: <https://webkit.org/b/269100> Add storage size of window.localStorage, window.sessionStorage and indexedDB.
        completionHandler(storageSize);
    }).get()];
}

void WebExtensionController::removeStorage(_WKWebExtensionStorageSQLiteStore *storage, WebExtensionDataType type, CompletionHandler<void()>&& completionHandler)
{
    [storage deleteDatabaseWithCompletionHandler:makeBlockPtr([completionHandler = WTFMove(completionHandler)](NSString *) mutable {
        // FIXME: <https://webkit.org/b/269100> Remove window.localStorage, window.sessionStorage, indexedDB.
        completionHandler();
    }).get()];
}

bool WebExtensionController::load(WebExtensionContext& extensionContext, NSError **outError)
{
    if (outError)
        *outError = nil;

    if (!m_extensionContexts.add(extensionContext)) {
        RELEASE_LOG_ERROR(Extensions, "Extension context already loaded");
        if (outError)
            *outError = extensionContext.createError(WebExtensionContext::Error::AlreadyLoaded);
        return false;
    }

    if (!m_extensionContextBaseURLMap.add(extensionContext.baseURL().protocolHostAndPort(), extensionContext)) {
        RELEASE_LOG_ERROR(Extensions, "Extension context already loaded with same base URL: %{private}@", (NSURL *)extensionContext.baseURL());
        m_extensionContexts.remove(extensionContext);
        if (outError)
            *outError = extensionContext.createError(WebExtensionContext::Error::BaseURLAlreadyInUse);
        return false;
    }

    for (Ref processPool : m_processPools)
        processPool->addMessageReceiver(Messages::WebExtensionContext::messageReceiverName(), extensionContext.identifier(), extensionContext);

    auto scheme = extensionContext.baseURL().protocol().toString();
    m_registeredSchemeHandlers.ensure(scheme, [&]() {
        Ref handler = WebExtensionURLSchemeHandler::create(*this);

        for (Ref page : m_pages)
            page->setURLSchemeHandlerForScheme(handler.copyRef(), scheme);

        return handler;
    });

    auto extensionDirectory = storageDirectory(extensionContext);
    if (!!extensionDirectory && !FileSystem::makeAllDirectories(extensionDirectory))
        RELEASE_LOG_ERROR(Extensions, "Failed to create directory: %{private}@", (NSString *)extensionDirectory);

    if (!extensionContext.load(*this, extensionDirectory, outError)) {
        m_extensionContexts.remove(extensionContext);
        m_extensionContextBaseURLMap.remove(extensionContext.baseURL().protocolHostAndPort());

        for (Ref processPool : m_processPools)
            processPool->removeMessageReceiver(Messages::WebExtensionContext::messageReceiverName(), extensionContext.identifier());

        return false;
    }

    sendToAllProcesses(Messages::WebExtensionControllerProxy::Load(extensionContext.parameters()), m_identifier);

    return true;
}

bool WebExtensionController::unload(WebExtensionContext& extensionContext, NSError **outError)
{
    if (outError)
        *outError = nil;

    Ref protectedExtensionContext = extensionContext;

    if (!m_extensionContexts.remove(extensionContext)) {
        RELEASE_LOG_ERROR(Extensions, "Extension context not loaded");
        if (outError)
            *outError = extensionContext.createError(WebExtensionContext::Error::NotLoaded);
        return false;
    }

    bool result = m_extensionContextBaseURLMap.remove(extensionContext.baseURL().protocolHostAndPort());
    UNUSED_VARIABLE(result);
    ASSERT(result);

    sendToAllProcesses(Messages::WebExtensionControllerProxy::Unload(extensionContext.identifier()), m_identifier);

    for (Ref processPool : m_processPools)
        processPool->removeMessageReceiver(Messages::WebExtensionContext::messageReceiverName(), extensionContext.identifier());

    if (!extensionContext.unload(outError))
        return false;

    return true;
}

void WebExtensionController::unloadAll()
{
    auto contextsCopy = m_extensionContexts;
    for (Ref context : contextsCopy)
        unload(context, nullptr);
}

void WebExtensionController::addPage(WebPageProxy& page)
{
    ASSERT(!m_pages.contains(page));
    m_pages.add(page);

    for (auto& entry : m_registeredSchemeHandlers)
        page.setURLSchemeHandlerForScheme(entry.value.copyRef(), entry.key);

    Ref pool = page.process().processPool();
    addProcessPool(pool);

    Ref dataStore = page.websiteDataStore();
    addWebsiteDataStore(dataStore);

    Ref controller = page.userContentController();
    addUserContentController(controller, dataStore->isPersistent() ? ForPrivateBrowsing::No : ForPrivateBrowsing::Yes);
}

void WebExtensionController::removePage(WebPageProxy& page)
{
    ASSERT(m_pages.contains(page));
    m_pages.remove(page);

    Ref pool = page.process().processPool();
    removeProcessPool(pool);

    Ref dataStore = page.websiteDataStore();
    removeWebsiteDataStore(dataStore);

    Ref controller = page.userContentController();
    removeUserContentController(controller);
}

void WebExtensionController::addProcessPool(WebProcessPool& processPool)
{
    if (!m_processPools.add(processPool))
        return;

    for (auto& urlScheme : WebExtensionMatchPattern::extensionSchemes()) {
        processPool.registerURLSchemeAsSecure(urlScheme);
        processPool.registerURLSchemeAsBypassingContentSecurityPolicy(urlScheme);
        processPool.setDomainRelaxationForbiddenForURLScheme(urlScheme);
    }

    processPool.addMessageReceiver(Messages::WebExtensionController::messageReceiverName(), m_identifier, *this);

    for (Ref context : m_extensionContexts)
        processPool.addMessageReceiver(Messages::WebExtensionContext::messageReceiverName(), context->identifier(), context);
}

void WebExtensionController::removeProcessPool(WebProcessPool& processPool)
{
    // Only remove the message receiver and process pool if no other pages use the same process pool.
    for (Ref knownPage : m_pages) {
        if (knownPage->process().processPool() == processPool)
            return;
    }

    processPool.removeMessageReceiver(Messages::WebExtensionController::messageReceiverName(), m_identifier);

    for (Ref context : m_extensionContexts)
        processPool.removeMessageReceiver(Messages::WebExtensionContext::messageReceiverName(), context->identifier());

    m_processPools.remove(processPool);
}

void WebExtensionController::addUserContentController(WebUserContentControllerProxy& userContentController, ForPrivateBrowsing forPrivateBrowsing)
{
    if (forPrivateBrowsing == ForPrivateBrowsing::No)
        m_allNonPrivateUserContentControllers.add(userContentController);
    else
        m_allPrivateUserContentControllers.add(userContentController);

    if (!m_allUserContentControllers.add(userContentController))
        return;

    for (Ref context : m_extensionContexts) {
        if (!context->hasAccessInPrivateBrowsing() && forPrivateBrowsing == ForPrivateBrowsing::Yes)
            continue;

        context->addInjectedContent(userContentController);
    }
}

void WebExtensionController::removeUserContentController(WebUserContentControllerProxy& userContentController)
{
    // Only remove the user content controller if no other pages use the same one.
    for (Ref knownPage : m_pages) {
        if (knownPage->userContentController() == userContentController)
            return;
    }

    for (Ref context : m_extensionContexts)
        context->removeInjectedContent(userContentController);

    m_allNonPrivateUserContentControllers.remove(userContentController);
    m_allPrivateUserContentControllers.remove(userContentController);
    m_allUserContentControllers.remove(userContentController);
}

WebsiteDataStore* WebExtensionController::websiteDataStore(std::optional<PAL::SessionID> sessionID) const
{
    if (!sessionID || configuration().defaultWebsiteDataStore().sessionID() == sessionID.value())
        return &configuration().defaultWebsiteDataStore();

    for (Ref dataStore : allWebsiteDataStores()) {
        if (dataStore->sessionID() == sessionID.value())
            return dataStore.ptr();
    }

    return nullptr;
}

void WebExtensionController::addWebsiteDataStore(WebsiteDataStore& dataStore)
{
    if (!m_cookieStoreObserver)
        m_cookieStoreObserver = makeUnique<HTTPCookieStoreObserver>(*this);

    m_websiteDataStores.add(dataStore);
    dataStore.cookieStore().registerObserver(*m_cookieStoreObserver);
}

void WebExtensionController::removeWebsiteDataStore(WebsiteDataStore& dataStore)
{
    // Only remove the data store if no other pages use the same one.
    for (Ref knownPage : m_pages) {
        if (knownPage->websiteDataStore() == dataStore)
            return;
    }

    m_websiteDataStores.remove(dataStore);
    dataStore.cookieStore().unregisterObserver(*m_cookieStoreObserver);

    if (m_websiteDataStores.isEmptyIgnoringNullReferences())
        m_cookieStoreObserver = nullptr;
}

void WebExtensionController::cookiesDidChange(API::HTTPCookieStore& cookieStore)
{
    // FIXME: <https://webkit.org/b/267514> Add support for changeInfo.

    for (Ref context : m_extensionContexts)
        context->cookiesDidChange(cookieStore);
}

RefPtr<WebExtensionContext> WebExtensionController::extensionContext(const WebExtension& extension) const
{
    for (Ref context : m_extensionContexts) {
        if (context->extension() == extension)
            return context.ptr();
    }

    return nullptr;
}

RefPtr<WebExtensionContext> WebExtensionController::extensionContext(const UniqueIdentifier& uniqueIdentifier) const
{
    for (Ref context : m_extensionContexts) {
        if (context->uniqueIdentifier() == uniqueIdentifier)
            return context.ptr();
    }

    return nullptr;
}

RefPtr<WebExtensionContext> WebExtensionController::extensionContext(const URL& url) const
{
    return m_extensionContextBaseURLMap.get(url.protocolHostAndPort());
}

WebExtensionController::WebExtensionSet WebExtensionController::extensions() const
{
    WebExtensionSet extensions;
    extensions.reserveInitialCapacity(m_extensionContexts.size());
    for (Ref context : m_extensionContexts)
        extensions.addVoid(context->extension());
    return extensions;
}

String WebExtensionController::stateFilePath(const String& uniqueIdentifier) const
{
    return FileSystem::pathByAppendingComponent(storageDirectory(uniqueIdentifier), WebExtensionContext::plistFileName());
}

String WebExtensionController::storageDirectory(const String& uniqueIdentifier) const
{
    return FileSystem::pathByAppendingComponent(m_configuration->storageDirectory(), uniqueIdentifier);
}

_WKWebExtensionStorageSQLiteStore *WebExtensionController::sqliteStore(const String& storageDirectory, WebExtensionDataType type, std::optional<RefPtr<WebExtensionContext>> extensionContext)
{
    if (type == WebExtensionDataType::Session) {
        ASSERT(extensionContext.has_value());

        return extensionContext.value()->isLoaded() ? extensionContext.value()->storageForType(WebExtensionDataType::Session) : nil;
    }

    auto uniqueIdentifier = FileSystem::lastComponentOfPathIgnoringTrailingSlash(storageDirectory);
    return [[_WKWebExtensionStorageSQLiteStore alloc] initWithUniqueIdentifier:uniqueIdentifier storageType:type directory:storageDirectory usesInMemoryDatabase:NO];
}

#if PLATFORM(MAC)
void WebExtensionController::addItemsToContextMenu(WebPageProxy& page, const ContextMenuContextData& contextData, NSMenu *menu)
{
    [menu addItem:NSMenuItem.separatorItem];

    for (Ref context : m_extensionContexts)
        context->addItemsToContextMenu(page, contextData, menu);
}
#endif

// MARK: webNavigation

void WebExtensionController::didStartProvisionalLoadForFrame(WebPageProxyIdentifier pageID, WebExtensionFrameIdentifier frameID, WebExtensionFrameIdentifier parentFrameID, const URL& targetURL, WallTime timestamp)
{
    for (Ref context : m_extensionContexts)
        context->didStartProvisionalLoadForFrame(pageID, frameID, parentFrameID, targetURL, timestamp);
}

void WebExtensionController::didCommitLoadForFrame(WebPageProxyIdentifier pageID, WebExtensionFrameIdentifier frameID, WebExtensionFrameIdentifier parentFrameID, const URL& frameURL, WallTime timestamp)
{
    for (Ref context : m_extensionContexts)
        context->didCommitLoadForFrame(pageID, frameID, parentFrameID, frameURL, timestamp);
}

void WebExtensionController::didFinishLoadForFrame(WebPageProxyIdentifier pageID, WebExtensionFrameIdentifier frameID, WebExtensionFrameIdentifier parentFrameID, const URL& frameURL, WallTime timestamp)
{
    for (Ref context : m_extensionContexts)
        context->didFinishLoadForFrame(pageID, frameID, parentFrameID, frameURL, timestamp);
}

void WebExtensionController::didFailLoadForFrame(WebPageProxyIdentifier pageID, WebExtensionFrameIdentifier frameID, WebExtensionFrameIdentifier parentFrameID, const URL& frameURL, WallTime timestamp)
{
    for (Ref context : m_extensionContexts)
        context->didFailLoadForFrame(pageID, frameID, parentFrameID, frameURL, timestamp);
}

// MARK: declarativeNetRequest

void WebExtensionController::handleContentRuleListNotification(WebPageProxyIdentifier pageID, URL& url, WebCore::ContentRuleListResults& results)
{
    bool savedMatchedRule = false;

    for (const auto& result : results.results) {
        auto contentRuleListIdentifier = result.first;
        for (Ref context : m_extensionContexts) {
            if (context->uniqueIdentifier() != contentRuleListIdentifier)
                continue;

            RefPtr tab = context->getTab(pageID);
            if (!tab)
                break;

            savedMatchedRule |= context->handleContentRuleListNotificationForTab(*tab, url, result.second);

            break;
        }
    }

    if (!savedMatchedRule || m_purgeOldMatchedRulesTimer)
        return;

    m_purgeOldMatchedRulesTimer = makeUnique<WebCore::Timer>(*this, &WebExtensionController::purgeOldMatchedRules);
    m_purgeOldMatchedRulesTimer->start(purgeMatchedRulesInterval, purgeMatchedRulesInterval);
}

void WebExtensionController::purgeOldMatchedRules()
{
    WallTime earliestDateToKeep = WallTime::now() - purgeMatchedRulesInterval;

    bool stillHaveRules = false;
    for (Ref context : m_extensionContexts)
        stillHaveRules |= context->purgeMatchedRulesFromBefore(earliestDateToKeep);

    if (!stillHaveRules)
        m_purgeOldMatchedRulesTimer = nullptr;
}

// MARK: webRequest

void WebExtensionController::resourceLoadDidSendRequest(WebPageProxyIdentifier pageID, const ResourceLoadInfo& loadInfo, const WebCore::ResourceRequest& request)
{
    for (Ref context : m_extensionContexts)
        context->resourceLoadDidSendRequest(pageID, loadInfo, request);
}

void WebExtensionController::resourceLoadDidPerformHTTPRedirection(WebPageProxyIdentifier pageID, const ResourceLoadInfo& loadInfo, const WebCore::ResourceResponse& response, const WebCore::ResourceRequest& request)
{
    for (Ref context : m_extensionContexts)
        context->resourceLoadDidPerformHTTPRedirection(pageID, loadInfo, response, request);
}

void WebExtensionController::resourceLoadDidReceiveChallenge(WebPageProxyIdentifier pageID, const ResourceLoadInfo& loadInfo, const WebCore::AuthenticationChallenge& challenge)
{
    for (Ref context : m_extensionContexts)
        context->resourceLoadDidReceiveChallenge(pageID, loadInfo, challenge);
}

void WebExtensionController::resourceLoadDidReceiveResponse(WebPageProxyIdentifier pageID, const ResourceLoadInfo& loadInfo, const WebCore::ResourceResponse& response)
{
    for (Ref context : m_extensionContexts)
        context->resourceLoadDidReceiveResponse(pageID, loadInfo, response);
}

void WebExtensionController::resourceLoadDidCompleteWithError(WebPageProxyIdentifier pageID, const ResourceLoadInfo& loadInfo, const WebCore::ResourceResponse& response, const WebCore::ResourceError& error)
{
    for (Ref context : m_extensionContexts)
        context->resourceLoadDidCompleteWithError(pageID, loadInfo, response, error);
}

// MARK: Inspector

#if ENABLE(INSPECTOR_EXTENSIONS)
void WebExtensionController::inspectorWillOpen(WebInspectorUIProxy& inspector, WebPageProxy& inspectedPage)
{
    for (Ref context : m_extensionContexts)
        context->inspectorWillOpen(inspector, inspectedPage);
}

void WebExtensionController::inspectorWillClose(WebInspectorUIProxy& inspector, WebPageProxy& inspectedPage)
{
    for (Ref context : m_extensionContexts)
        context->inspectorWillClose(inspector, inspectedPage);
}
#endif // ENABLE(INSPECTOR_EXTENSIONS)

} // namespace WebKit

#endif // ENABLE(WK_WEB_EXTENSIONS)
