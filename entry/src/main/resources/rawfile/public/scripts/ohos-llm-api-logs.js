import { getRequestHeaders } from '../script.js';
import { callGenericPopup, POPUP_TYPE } from './popup.js';
import { translate } from './i18n.js';

const LOG_STREAM_URL = '/api/dev/llm-api-logs/stream';
const LOG_INDEX_URL = '/api/dev/llm-api-logs';
const LOG_PREVIEW_URL = '/api/dev/llm-api-logs/preview';
const LOG_RAW_URL = '/api/dev/llm-api-logs/raw';
const LOG_SETTINGS_URL = '/api/dev/llm-api-logs/settings';
const MONOSPACE_FONT = 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace';

function runOrPopup(task) {
    void (async () => {
        try {
            await task();
        } catch (error) {
            const message = error?.message ? String(error.message) : String(error);
            await callGenericPopup(translate(message), POPUP_TYPE.TEXT, '', {
                okButton: translate('OK'),
                allowVerticalScrolling: true,
            });
        }
    })();
}

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

function formatTimestamp(ms) {
    const date = new Date(Number(ms) || 0);
    if (Number.isNaN(date.getTime())) {
        return 'Invalid time';
    }
    return date.toLocaleString();
}

function entryTitle(entry) {
    if (!entry) {
        return translate('No entries');
    }
    const model = entry.model ? ` (${entry.model})` : '';
    const stream = entry.stream ? ' stream' : ' json';
    const ok = entry.ok === false ? 'ERROR' : 'OK';
    return `#${entry.id} ${entry.source}${model} ${ok}${stream} ${entry.durationMs ?? 0}ms`;
}

function setButtonDisabled(button, disabled) {
    button.classList.toggle('disabled', disabled);
    button.style.opacity = disabled ? '0.55' : '';
    button.style.pointerEvents = disabled ? 'none' : '';
}

function textArea(rows, placeholder) {
    const textarea = document.createElement('textarea');
    textarea.rows = rows;
    textarea.readOnly = true;
    textarea.spellcheck = false;
    textarea.className = 'text_pole';
    textarea.placeholder = placeholder;
    textarea.style.width = '100%';
    textarea.style.resize = 'vertical';
    textarea.style.fontFamily = MONOSPACE_FONT;
    return textarea;
}

function button(label, icon) {
    const el = document.createElement('div');
    el.className = 'menu_button menu_button_icon';
    const iconEl = document.createElement('i');
    iconEl.className = `fa-solid ${icon}`;
    const text = document.createElement('span');
    text.textContent = label;
    el.append(iconEl, text);
    return el;
}

function section(title, textarea) {
    const block = document.createElement('div');
    block.className = 'flex-container flexFlowColumn';
    block.style.gap = '6px';
    const label = document.createElement('b');
    label.textContent = title;
    block.append(label, textarea);
    return block;
}

async function openLlmApiLogsPanel() {
    let settings = await getJson(LOG_SETTINGS_URL);
    let keep = Number(settings.keep) > 0 ? Number(settings.keep) : 5;
    let entries = await postJson(LOG_INDEX_URL, { limit: keep });
    if (!Array.isArray(entries)) {
        entries = [];
    }

    let index = Math.max(0, entries.length - 1);
    let currentPreview = null;
    let currentRaw = null;
    let eventSource = null;
    let streamEnabled = settings.streamEnabled === true;

    const root = document.createElement('div');
    root.className = 'flex-container flexFlowColumn';
    root.style.gap = '10px';

    const header = document.createElement('div');
    header.className = 'flex-container alignitemscenter';
    header.style.gap = '10px';
    header.style.flexWrap = 'wrap';

    const title = document.createElement('b');
    title.textContent = translate('LLM API Logs');
    header.append(title);

    const prevButton = button(translate('Prev'), 'fa-chevron-left');
    const nextButton = button(translate('Next'), 'fa-chevron-right');
    const reloadButton = button(translate('Reload'), 'fa-arrows-rotate');
    const copyRequestButton = button(translate('Copy Request'), 'fa-copy');
    const copyResponseButton = button(translate('Copy Response'), 'fa-copy');
    const position = document.createElement('small');
    position.style.opacity = '0.85';

    header.append(prevButton, nextButton, reloadButton, copyRequestButton, copyResponseButton, position);
    root.append(header);

    const settingsRow = document.createElement('div');
    settingsRow.className = 'flex-container alignitemscenter';
    settingsRow.style.gap = '10px';
    settingsRow.style.flexWrap = 'wrap';

    const keepLabel = document.createElement('span');
    keepLabel.textContent = translate('Keep');
    const keepInput = document.createElement('input');
    keepInput.type = 'number';
    keepInput.min = '1';
    keepInput.max = '100';
    keepInput.step = '1';
    keepInput.value = String(keep);
    keepInput.className = 'text_pole';
    keepInput.style.width = '100px';
    keepInput.style.margin = '0';

    const applyKeepButton = button(translate('Apply'), 'fa-check');

    const liveLabel = document.createElement('label');
    liveLabel.className = 'checkbox_label flexNoGap';
    const liveToggle = document.createElement('input');
    liveToggle.type = 'checkbox';
    liveToggle.checked = streamEnabled;
    const liveText = document.createElement('span');
    liveText.textContent = translate('Live');
    liveLabel.append(liveToggle, liveText);

    settingsRow.append(keepLabel, keepInput, applyKeepButton, liveLabel);
    root.append(settingsRow);

    const meta = document.createElement('div');
    meta.style.whiteSpace = 'pre-wrap';
    meta.style.opacity = '0.9';
    root.append(meta);

    const requestBox = textArea(8, translate('Request body'));
    const responseBox = textArea(10, translate('Response body'));
    root.append(section(translate('Request body'), requestBox));
    root.append(section(translate('Response body'), responseBox));

    const rawDetails = document.createElement('details');
    rawDetails.style.border = '1px solid rgba(255,255,255,0.12)';
    rawDetails.style.borderRadius = '6px';
    rawDetails.style.padding = '8px';
    const rawSummary = document.createElement('summary');
    rawSummary.textContent = translate('Raw JSON/SSE');
    rawSummary.style.cursor = 'pointer';
    rawDetails.append(rawSummary);

    const rawRequestBox = textArea(8, translate('Raw request'));
    const rawResponseBox = textArea(10, translate('Raw response'));
    const rawControls = document.createElement('div');
    rawControls.className = 'flex-container';
    rawControls.style.gap = '10px';
    rawControls.style.flexWrap = 'wrap';
    rawControls.style.margin = '10px 0';
    const copyRawRequestButton = button(translate('Copy Raw Request'), 'fa-copy');
    const copyRawResponseButton = button(translate('Copy Raw Response'), 'fa-copy');
    rawControls.append(copyRawRequestButton, copyRawResponseButton);
    rawDetails.append(rawControls, section(translate('Raw request'), rawRequestBox), section(translate('Raw response'), rawResponseBox));
    root.append(rawDetails);

    const currentEntry = () => entries[index] ?? null;
    const currentId = () => Number(currentEntry()?.id ?? 0);

    const mergeEntry = (entry) => {
        const id = Number(entry?.id ?? 0);
        if (id <= 0) {
            return false;
        }
        const existingIndex = entries.findIndex((item) => Number(item?.id ?? 0) === id);
        if (existingIndex >= 0) {
            entries[existingIndex] = entry;
            return false;
        }
        entries.push(entry);
        entries.sort((left, right) => Number(left?.id ?? 0) - Number(right?.id ?? 0));
        if (entries.length > keep) {
            entries.splice(0, entries.length - keep);
        }
        return true;
    };

    const loadPreview = async () => {
        const id = currentId();
        currentPreview = id > 0 ? await getJson(`${LOG_PREVIEW_URL}?id=${encodeURIComponent(id)}`) : null;
    };

    const loadRaw = async () => {
        const id = currentId();
        currentRaw = id > 0 ? await getJson(`${LOG_RAW_URL}?id=${encodeURIComponent(id)}`) : null;
    };

    const render = () => {
        const entry = currentEntry();
        position.textContent = entries.length > 0 ? `${index + 1}/${entries.length}` : translate('No entries');
        setButtonDisabled(prevButton, index <= 0);
        setButtonDisabled(nextButton, index >= entries.length - 1);

        if (!entry) {
            meta.textContent = '';
            requestBox.value = '';
            responseBox.value = '';
            rawRequestBox.value = '';
            rawResponseBox.value = '';
            return;
        }

        const preview = currentPreview?.id === entry.id ? currentPreview : null;
        meta.textContent = `${entryTitle(entry)}\n${entry.endpoint || ''}\n${formatTimestamp(entry.timestampMs)}`;
        requestBox.value = preview ? (preview.requestReadable || '') : translate('Loading...');
        responseBox.value = preview ? (preview.responseReadable || '') : translate('Loading...');

        if (!rawDetails.open) {
            rawRequestBox.value = '';
            rawResponseBox.value = '';
            return;
        }
        const raw = currentRaw?.id === entry.id ? currentRaw : null;
        rawRequestBox.value = raw ? (raw.requestRaw || '') : translate('Loading...');
        rawResponseBox.value = raw ? (raw.responseRaw || '') : translate('Loading...');
    };

    const selectIndex = async (nextIndex) => {
        if (entries.length === 0) {
            index = 0;
            render();
            return;
        }
        index = Math.max(0, Math.min(nextIndex, entries.length - 1));
        currentPreview = null;
        currentRaw = null;
        render();
        await loadPreview();
        if (rawDetails.open) {
            await loadRaw();
        }
        render();
    };

    const reloadEntries = async () => {
        entries = await postJson(LOG_INDEX_URL, { limit: keep });
        if (!Array.isArray(entries)) {
            entries = [];
        }
        await selectIndex(Math.max(0, entries.length - 1));
    };

    const stopLive = async () => {
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }
        streamEnabled = false;
        liveToggle.checked = false;
        await postJson(LOG_SETTINGS_URL, { keep, streamEnabled: false });
    };

    const startLive = async () => {
        if (eventSource) {
            return;
        }
        streamEnabled = true;
        liveToggle.checked = true;
        await postJson(LOG_SETTINGS_URL, { keep, streamEnabled: true });
        eventSource = new EventSource(LOG_STREAM_URL);
        eventSource.addEventListener('llm-api-log', (event) => {
            try {
                const entry = JSON.parse(event.data);
                const shouldFollowTail = index >= entries.length - 1;
                mergeEntry(entry);
                if (shouldFollowTail) {
                    void selectIndex(Math.max(0, entries.length - 1));
                } else {
                    if (currentId() === Number(entry?.id ?? 0)) {
                        currentPreview = null;
                        currentRaw = null;
                    }
                    render();
                }
            } catch (error) {
                console.warn('Failed to parse LLM API log event', error);
            }
        });
        eventSource.onerror = () => {
            console.warn('LLM API log stream disconnected');
        };
    };

    prevButton.addEventListener('click', () => runOrPopup(async () => selectIndex(index - 1)));
    nextButton.addEventListener('click', () => runOrPopup(async () => selectIndex(index + 1)));
    reloadButton.addEventListener('click', () => runOrPopup(reloadEntries));
    applyKeepButton.addEventListener('click', () => runOrPopup(async () => {
        const nextKeep = Math.floor(Number(keepInput.value));
        if (!Number.isFinite(nextKeep) || nextKeep <= 0) {
            throw new Error('Keep must be a positive integer');
        }
        keep = Math.min(100, nextKeep);
        keepInput.value = String(keep);
        await postJson(LOG_SETTINGS_URL, { keep, streamEnabled });
        await reloadEntries();
    }));
    liveToggle.addEventListener('change', () => runOrPopup(async () => {
        if (liveToggle.checked) {
            await startLive();
        } else {
            await stopLive();
        }
    }));
    rawDetails.addEventListener('toggle', () => runOrPopup(async () => {
        currentRaw = null;
        render();
        if (rawDetails.open) {
            await loadRaw();
            render();
        }
    }));
    copyRequestButton.addEventListener('click', () => runOrPopup(async () => navigator.clipboard.writeText(requestBox.value)));
    copyResponseButton.addEventListener('click', () => runOrPopup(async () => navigator.clipboard.writeText(responseBox.value)));
    copyRawRequestButton.addEventListener('click', () => runOrPopup(async () => navigator.clipboard.writeText(rawRequestBox.value)));
    copyRawResponseButton.addEventListener('click', () => runOrPopup(async () => navigator.clipboard.writeText(rawResponseBox.value)));

    try {
        await selectIndex(index);
        if (streamEnabled) {
            await startLive();
        }
        await callGenericPopup(root, POPUP_TYPE.TEXT, '', {
            okButton: translate('Close'),
            allowVerticalScrolling: true,
            wide: true,
            large: true,
        });
    } finally {
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }
        if (streamEnabled) {
            await postJson(LOG_SETTINGS_URL, { keep, streamEnabled: false });
        }
    }
}

export function initOhosLlmApiLogs() {
    $('#ohos_open_llm_api_logs').on('click', () => runOrPopup(openLlmApiLogsPanel));
}
