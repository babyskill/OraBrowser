import Foundation

enum AIUserScripts {
    static let chatGPT = #"""
    (() => {
        if (!/(^|\.)chatgpt\.com$|^chat\.openai\.com$/.test(location.hostname)) return;
        let active = false;
        const post = (isStarting) => {
            if (active === isStarting) return;
            active = isStarting;
            window.webkit?.messageHandlers?.oraAIActivity?.postMessage({
                status: isStarting ? "started" : "stopped",
                type: "aiGeneration"
            });
        };
        const detect = () => {
            const stopButton = document.querySelector(
                'button[data-testid="stop-button"], button[aria-label*="Stop" i], button[title*="Stop" i]'
            );
            const streaming = document.querySelector('.result-streaming, [data-is-streaming="true"]');
            post(Boolean(stopButton || streaming));
        };
        new MutationObserver(detect).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true
        });
        detect();
    })();
    """#

    static let gemini = #"""
    (() => {
        if (location.hostname !== 'gemini.google.com') return;
        let active = false;
        const post = (isStarting) => {
            if (active === isStarting) return;
            active = isStarting;
            window.webkit?.messageHandlers?.oraAIActivity?.postMessage({
                status: isStarting ? "started" : "stopped",
                type: "aiGeneration"
            });
        };
        const detect = () => {
            const stopButton = document.querySelector(
                'button[aria-label*="Stop" i], button[mattooltip*="Stop" i], .stop-button'
            );
            const streaming = document.querySelector(
                '.assistant-message-response[data-is-streaming="true"], [aria-busy="true"]'
            );
            post(Boolean(stopButton || streaming));
        };
        new MutationObserver(detect).observe(document.documentElement, {
            childList: true, subtree: true, attributes: true
        });
        detect();
    })();
    """#

    static let mediaPlayback = #"""
    (() => {
        const playing = new Set();
        let active = false;
        const update = () => {
            const next = playing.size > 0;
            if (next === active) return;
            active = next;
            window.webkit?.messageHandlers?.oraAIActivity?.postMessage({
                status: next ? "started" : "stopped",
                type: "mediaPlayback"
            });
        };
        document.addEventListener('play', (event) => {
            if (event.target instanceof HTMLMediaElement) {
                playing.add(event.target);
                update();
            }
        }, true);
        for (const eventName of ['pause', 'ended', 'emptied']) {
            document.addEventListener(eventName, (event) => {
                if (event.target instanceof HTMLMediaElement) {
                    playing.delete(event.target);
                    update();
                }
            }, true);
        }
    })();
    """#
}
