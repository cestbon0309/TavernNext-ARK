import { getRequestHeaders } from '../script.js';

const SETTINGS_URL = '/api/ohos/background-privacy/settings';

let initialized = false;

async function getJson(url, options = {}) {
    const response = await fetch(url, options);
    if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}`);
    }
    return await response.json();
}

async function postJson(url, body) {
    return await getJson(url, {
        method: 'POST',
        headers: getRequestHeaders(),
        body: JSON.stringify(body),
    });
}

async function refreshBackgroundPrivacySettings() {
    const checkbox = $('#ohos_background_privacy_enabled');
    const settings = await getJson(SETTINGS_URL);
    checkbox.prop('checked', settings.enabled === true);
    checkbox.prop('disabled', false);
}

export function initOhosBackgroundPrivacy() {
    if (initialized) {
        return;
    }
    initialized = true;

    const checkbox = $('#ohos_background_privacy_enabled');
    if (checkbox.length === 0) {
        return;
    }

    checkbox.prop('disabled', true);
    void refreshBackgroundPrivacySettings().catch((error) => {
        console.warn('Failed to load background privacy settings', error);
        checkbox.prop('checked', true);
        checkbox.prop('disabled', false);
    });

    checkbox.on('change', async () => {
        const enabled = checkbox.prop('checked') === true;
        checkbox.prop('disabled', true);
        try {
            const settings = await postJson(SETTINGS_URL, { enabled });
            checkbox.prop('checked', settings.enabled === true);
        } catch (error) {
            console.warn('Failed to save background privacy settings', error);
            checkbox.prop('checked', !enabled);
            toastr.error('后台隐私保护设置保存失败');
        } finally {
            checkbox.prop('disabled', false);
        }
    });
}
