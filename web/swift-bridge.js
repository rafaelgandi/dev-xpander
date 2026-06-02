function sendMessageToSwift(action, data = {}) {
    return new Promise((resolve, reject) => {
        if (!window.webkit?.messageHandlers?.swiftBridge) {
            reject(new Error('Native bridge is not available.'));
            return;
        }
        const suffix = `${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
        const eventName = `swift:${action}:${suffix}`;
        const errorEventName = `swift:${action}:error:${suffix}`;

        const timeout = window.setTimeout(() => {
            window.removeEventListener(eventName, onSuccess);
            window.removeEventListener(errorEventName, onError);
            reject(new Error('Timed out waiting for native response.'));
        }, 30000);

        function onSuccess(event) {
            window.clearTimeout(timeout);
            window.removeEventListener(eventName, onSuccess);
            window.removeEventListener(errorEventName, onError);
            resolve(event.detail);
        }

        function onError(event) {
            window.clearTimeout(timeout);
            window.removeEventListener(eventName, onSuccess);
            window.removeEventListener(errorEventName, onError);
            reject(new Error(event.detail ?? 'Native error.'));
        }

        window.addEventListener(eventName, onSuccess, { once: true });
        window.addEventListener(errorEventName, onError, { once: true });

        const payload = {
            action,
            data: {
                ...data,
                _eventName: eventName,
                _errorEventName: errorEventName,
            },
        };

        window.webkit.messageHandlers.swiftBridge.postMessage(JSON.stringify(payload));
    });
}
