const dom = {
    grantPermissionButton: document.getElementById('grantPermissionButton'),
    accessibilityStatus: document.getElementById('accessibilityStatus'),
    opencodePath: document.getElementById('opencodePath'),
    opencodePathBrowseButton: document.getElementById('opencodePathBrowseButton'),
    opencodePathResetButton: document.getElementById('opencodePathResetButton'),
    storagePath: document.getElementById('storagePath'),
    importButton: document.getElementById('importButton'),
    exportButton: document.getElementById('exportButton'),
    newSnippetButton: document.getElementById('newSnippetButton'),
    editorHeading: document.getElementById('editorHeading'),
    snippetForm: document.getElementById('snippetForm'),
    titleInput: document.getElementById('titleInput'),
    expansionInput: document.getElementById('expansionInput'),
    notesInput: document.getElementById('notesInput'),
    saveSnippetButton: document.getElementById('saveSnippetButton'),
    cancelEditButton: document.getElementById('cancelEditButton'),
    aiImproveButton: document.getElementById('aiImproveButton'),
    aiImproveLabel: document.getElementById('aiImproveLabel'),
    aiResultModal: document.getElementById('aiResultModal'),
    aiResultOutput: document.getElementById('aiResultOutput'),
    aiResultCopyButton: document.getElementById('aiResultCopyButton'),
    aiResultCloseButton: document.getElementById('aiResultCloseButton'),
    aiResultDoneButton: document.getElementById('aiResultDoneButton'),
    snippetsList: document.getElementById('snippetsList'),
    searchInput: document.getElementById('searchInput'),
    searchClearButton: document.getElementById('searchClearButton'),
    flashMessage: document.getElementById('flashMessage'),
};

const state = {
    snippets: [],
    hasAccessibilityPermission: false,
    storagePath: '',
    opencodePath: '',
    editingOriginalTitle: null,
    searchQuery: '',
};

const drag = {
    fromIndex: null,
    overIndex: null,
    above: false,
};

function showFlash(message, isError = false) {
    dom.flashMessage.textContent = message;
    dom.flashMessage.classList.remove('hidden', 'flash--error', 'flash--success');
    if (isError) {
        dom.flashMessage.classList.add('flash--error');
    }
    else {
        dom.flashMessage.classList.add('flash--success');
    }
    window.clearTimeout(showFlash._timer);
    showFlash._timer = window.setTimeout(() => {
        dom.flashMessage.classList.add('hidden');
    }, 3000);
}

function normalizeSnippetRow(row) {
    const titleValue = (row.title ?? row.keyword ?? '').trim();
    return { title: titleValue, expansion: row.expansion ?? '', notes: row.notes ?? '', hidden: Boolean(row.hidden) };
}

function escapeHtml(value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
}

function applyPayload(payload) {
    if (!payload) {
        return;
    }
    state.snippets = Array.isArray(payload.snippets)
        ? payload.snippets.map(normalizeSnippetRow)
        : [];
    state.hasAccessibilityPermission = Boolean(payload.hasAccessibilityPermission);
    state.storagePath = payload.storagePath ?? '';
    state.opencodePath = payload.opencodePath ?? '';
    render();
}

function render() {
    dom.accessibilityStatus.textContent = state.hasAccessibilityPermission ? 'Granted' : 'Not Granted';
    dom.storagePath.textContent = state.storagePath || 'Unknown';
    dom.opencodePath.textContent = state.opencodePath || 'Auto-detected';
    dom.cancelEditButton.classList.toggle('hidden', !state.editingOriginalTitle);
    dom.saveSnippetButton.textContent = state.editingOriginalTitle ? 'Update Snippet' : 'Save Snippet';
    dom.editorHeading.textContent = state.editingOriginalTitle
        ? `Editing: ${state.editingOriginalTitle}`
        : 'New Snippet';
    renderSearchClear();
    renderSnippets();
    updateAiImproveButtonState();
}

function getFilteredSnippets() {
    const query = state.searchQuery.trim().toLowerCase();
    if (!query) {
        return state.snippets.map((snippet, index) => ({ snippet, index }));
    }
    const matches = [];
    state.snippets.forEach((snippet, index) => {
        const haystack = [
            snippet.title ?? '',
            snippet.expansion ?? '',
            snippet.notes ?? '',
        ].join('\n').toLowerCase();
        if (haystack.includes(query)) {
            matches.push({ snippet, index });
        }
    });
    return matches;
}

function renderSearchClear() {
    dom.searchClearButton.classList.toggle('hidden', state.searchQuery.length === 0);
}

function renderSnippets() {
    if (state.snippets.length === 0) {
        dom.snippetsList.innerHTML = '<p>No snippets yet. Add one with a menu label and text in the editor.</p>';
        return;
    }

    const filtered = getFilteredSnippets();
    if (filtered.length === 0) {
        dom.snippetsList.innerHTML = '<p>No snippets match your search.</p>';
        return;
    }

    const html = filtered.map(({ snippet, index }) => {
        const title = escapeHtml(snippet.title ?? '');
        const expansion = escapeHtml(snippet.expansion ?? '');
        const notes = escapeHtml(snippet.notes ?? '').trim();
        const isSelected = Boolean(state.editingOriginalTitle)
            && snippet.title === state.editingOriginalTitle;
        const isHidden = Boolean(snippet.hidden);
        const notesHtml = notes
            ? `<p class="snippet-notes"><span class="snippet-notes-dot"></span>Has notes</p>`
            : '';
        const selectedClass = isSelected ? ' is-selected' : '';
        const hiddenClass = isHidden ? ' is-hidden' : '';
        const hideIcon = isHidden
            ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" x2="22" y1="2" y2="22"/></svg>'
            : '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg>';
        return `
            <article class="snippet-item${selectedClass}${hiddenClass}" data-action="edit" data-index="${index}" draggable="true" tabindex="0" role="button" aria-label="Edit snippet ${title}">
                <div class="snippet-item-header">
                    <span class="snippet-title" title="${title}">${title}</span>
                    <div class="snippet-item-actions">
                        <button class="button button-copy button-copy--toggle" type="button" data-action="toggle-hidden" data-index="${index}" title="${isHidden ? 'Show in menu bar' : 'Hide from menu bar'}" aria-label="${isHidden ? 'Show in menu bar' : 'Hide from menu bar'}">
                            ${hideIcon}
                        </button>
                        <button class="button button-copy" type="button" data-action="copy" data-index="${index}" title="Copy to clipboard" aria-label="Copy snippet">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>
                                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
                            </svg>
                        </button>
                        <button class="button button-copy button-copy--danger" type="button" data-action="delete" data-index="${index}" title="Delete snippet" aria-label="Delete snippet">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M3 6h18"/>
                                <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/>
                                <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>
                            </svg>
                        </button>
                    </div>
                </div>
                <p class="snippet-expansion">${expansion}</p>
                ${notesHtml}
                ${isHidden ? '<span class="snippet-hidden-badge">Hidden from menu bar</span>' : ''}
            </article>
        `;
    }).join('');

    dom.snippetsList.innerHTML = html;
}

function normalizedTitle(value) {
    return value.trim();
}

function hasSnippetBody(value) {
    return value.trim().length > 0;
}

function isAiImproveBusy() {
    return dom.aiImproveButton?.dataset.busy === 'true';
}

function updateAiImproveButtonState() {
    if (!dom.aiImproveButton) return;
    if (isAiImproveBusy()) return;
    dom.aiImproveButton.disabled = !hasSnippetBody(dom.expansionInput.value);
}

async function saveSnippetsToNative() {
    try {
        const payload = await sendMessageToSwift('set-snippets', {
            snippets: state.snippets.map((s) => ({ title: s.title, expansion: s.expansion, notes: s.notes, hidden: s.hidden })),
        });
        applyPayload(payload);
    }
    catch (error) {
        showFlash(error.message ?? 'Failed to save snippets.', true);
        throw error;
    }
}

function resetForm() {
    state.editingOriginalTitle = null;
    dom.titleInput.value = '';
    dom.expansionInput.value = '';
    dom.notesInput.value = '';
    render();
}

function startEditing(index) {
    const snippet = state.snippets[index];
    if (!snippet) {
        return;
    }
    state.editingOriginalTitle = snippet.title;
    dom.titleInput.value = snippet.title;
    dom.expansionInput.value = snippet.expansion;
    dom.notesInput.value = snippet.notes ?? '';
    dom.titleInput.focus();
    render();
}

async function copySnippet(index) {
    const snippet = state.snippets[index];
    if (!snippet) return;
    try {
        await navigator.clipboard.writeText(snippet.expansion);
        showFlash('Copied to clipboard.');
    } catch {
        showFlash('Failed to copy to clipboard.', true);
    }
}

async function deleteSnippet(index) {
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion, notes: s.notes, hidden: s.hidden }));
    const next = state.snippets.filter((_, i) => i !== index);
    state.snippets = next;
    try {
        await saveSnippetsToNative();
        showFlash('Snippet deleted.');
        if (state.editingOriginalTitle) {
            const stillExists = state.snippets.some((snippet) => snippet.title === state.editingOriginalTitle);
            if (!stillExists) {
                resetForm();
            }
        }
    }
    catch {
        state.snippets = previousSnippets;
        render();
    }
}

async function toggleHidden(index) {
    const snippet = state.snippets[index];
    if (!snippet) {
        return;
    }
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion, notes: s.notes, hidden: s.hidden }));
    state.snippets[index] = { ...snippet, hidden: !snippet.hidden };
    try {
        await saveSnippetsToNative();
        showFlash(snippet.hidden ? 'Snippet shown in menu bar.' : 'Snippet hidden from menu bar.');
    }
    catch {
        state.snippets = previousSnippets;
        render();
    }
}

async function reorderSnippets(fromIndex, toIndex, above) {
    if (fromIndex === null || toIndex === null || fromIndex === toIndex) {
        return;
    }
    let insertAt = above ? toIndex : toIndex + 1;
    if (fromIndex < insertAt) {
        insertAt -= 1;
    }
    if (insertAt < 0) {
        insertAt = 0;
    }
    if (insertAt > state.snippets.length) {
        insertAt = state.snippets.length;
    }
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion, notes: s.notes, hidden: s.hidden }));
    const [moved] = state.snippets.splice(fromIndex, 1);
    state.snippets.splice(insertAt, 0, moved);
    try {
        await saveSnippetsToNative();
    }
    catch {
        state.snippets = previousSnippets;
        render();
    }
}

async function handleFormSubmit(event) {
    event.preventDefault();
    const title = normalizedTitle(dom.titleInput.value);
    const expansion = dom.expansionInput.value;
    const notes = dom.notesInput.value;
    if (!title) {
        showFlash('Menu label is required.', true);
        return;
    }
    if (!hasSnippetBody(expansion)) {
        showFlash('Snippet text cannot be empty.', true);
        return;
    }

    const duplicateIndex = state.snippets.findIndex(
        (snippet) => snippet.title.toLowerCase() === title.toLowerCase(),
    );
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion, notes: s.notes, hidden: s.hidden }));
    const previousEditing = state.editingOriginalTitle;

    if (state.editingOriginalTitle) {
        const filtered = state.snippets.filter((snippet) => snippet.title !== state.editingOriginalTitle);
        filtered.push({ title, expansion, notes });
        state.snippets = filtered;
    }
    else {
        if (duplicateIndex >= 0) {
            showFlash('That menu label already exists. Edit it instead.', true);
            return;
        }
        state.snippets = [...state.snippets, { title, expansion, notes }];
    }

    try {
        await saveSnippetsToNative();
        showFlash(previousEditing ? 'Snippet updated.' : 'Snippet saved.');
        resetForm();
    }
    catch {
        state.snippets = previousSnippets;
        state.editingOriginalTitle = previousEditing;
        render();
    }
}

async function requestAccessibilityPermission() {
    try {
        await sendMessageToSwift('request-accessibility');
        const payload = await sendMessageToSwift('get-app-state');
        applyPayload(payload);
        showFlash(state.hasAccessibilityPermission ? 'Accessibility granted.' : 'Permission is still not granted.', !state.hasAccessibilityPermission);
    }
    catch (error) {
        showFlash(error.message ?? 'Failed to request accessibility.', true);
    }
}

async function browseOpencodePath() {
    try {
        const payload = await sendMessageToSwift('browse-opencode-path');
        if (payload) {
            applyPayload(payload);
            showFlash('OpenCode binary updated.');
        }
    }
    catch (error) {
        showFlash(error.message ?? 'Failed to set OpenCode path.', true);
    }
}

async function resetOpencodePath() {
    try {
        const payload = await sendMessageToSwift('reset-opencode-path');
        applyPayload(payload);
        showFlash('Reverted to auto-detected OpenCode path.');
    }
    catch (error) {
        showFlash(error.message ?? 'Failed to reset OpenCode path.', true);
    }
}

async function aiImproveSnippet() {
    const currentText = dom.expansionInput.value;
    if (!hasSnippetBody(currentText)) {
        showFlash('Add some snippet text before improving it.', true);
        return;
    }
    if (dom.aiImproveButton?.dataset.busy === 'true') {
        return;
    }

    const originalLabel = dom.aiImproveLabel.textContent;
    dom.aiImproveButton.dataset.busy = 'true';
    dom.aiImproveButton.disabled = true;
    dom.aiImproveLabel.textContent = 'Improving…';

    try {
        const result = await sendMessageToSwift('ai-improve', { text: currentText }, 180000);
        const improved = (result?.improved ?? '').trim();
        if (!improved) {
            showFlash('AI returned an empty response.', true);
            return;
        }
        openAiResultModal(improved);
    }
    catch (error) {
        showFlash(error.message ?? 'AI improve failed.', true);
    }
    finally {
        dom.aiImproveButton.dataset.busy = 'false';
        dom.aiImproveLabel.textContent = originalLabel;
        updateAiImproveButtonState();
    }
}

function openAiResultModal(improvedText) {
    dom.aiResultOutput.value = improvedText;
    dom.aiResultModal.classList.remove('hidden');
    dom.aiResultCopyButton.focus();
}

function closeAiResultModal() {
    dom.aiResultModal.classList.add('hidden');
    dom.aiResultOutput.value = '';
}

async function copyAiResult() {
    const text = dom.aiResultOutput.value;
    if (!text) return;
    try {
        await navigator.clipboard.writeText(text);
        showFlash('Improved prompt copied to clipboard.');
        closeAiResultModal();
    } catch {
        showFlash('Failed to copy to clipboard.', true);
    }
}

async function importSnippets() {
    try {
        const payload = await sendMessageToSwift('import-snippets');
        if (payload) {
            applyPayload(payload);
            resetForm();
            showFlash('Snippets imported.');
        }
    }
    catch (error) {
        showFlash(error.message ?? 'Import failed.', true);
    }
}

async function exportSnippets() {
    try {
        const payload = await sendMessageToSwift('export-snippets');
        if (payload?.path) {
            showFlash(`Exported to ${payload.path}`);
        }
    }
    catch (error) {
        showFlash(error.message ?? 'Export failed.', true);
    }
}

async function loadInitialState() {
    try {
        const payload = await sendMessageToSwift('get-app-state');
        if (payload == null) {
            showFlash('Could not read app state.', true);
            dom.storagePath.textContent = '—';
            dom.accessibilityStatus.textContent = '?';
            return;
        }
        applyPayload(payload);
    }
    catch (error) {
        dom.storagePath.textContent = '—';
        showFlash(error.message ?? 'Failed to load app state.', true);
    }
}

function wireEvents() {
    dom.grantPermissionButton.addEventListener('click', () => {
        requestAccessibilityPermission();
    });

    dom.opencodePathBrowseButton.addEventListener('click', () => {
        browseOpencodePath();
    });

    dom.opencodePathResetButton.addEventListener('click', () => {
        resetOpencodePath();
    });

    dom.newSnippetButton.addEventListener('click', () => {
        resetForm();
        dom.titleInput.focus();
    });

    dom.searchInput.addEventListener('input', () => {
        state.searchQuery = dom.searchInput.value;
        renderSearchClear();
        renderSnippets();
    });

    dom.searchClearButton.addEventListener('click', () => {
        dom.searchInput.value = '';
        state.searchQuery = '';
        renderSearchClear();
        renderSnippets();
        dom.searchInput.focus();
    });

    dom.snippetForm.addEventListener('submit', (event) => {
        handleFormSubmit(event);
    });

    dom.expansionInput.addEventListener('input', () => {
        updateAiImproveButtonState();
    });

    dom.cancelEditButton.addEventListener('click', () => {
        resetForm();
    });

    dom.importButton.addEventListener('click', () => {
        importSnippets();
    });

    dom.exportButton.addEventListener('click', () => {
        exportSnippets();
    });

    dom.aiImproveButton.addEventListener('click', () => {
        aiImproveSnippet();
    });

    dom.aiResultCopyButton.addEventListener('click', () => {
        copyAiResult();
    });

    dom.aiResultCloseButton.addEventListener('click', () => {
        closeAiResultModal();
    });

    dom.aiResultDoneButton.addEventListener('click', () => {
        closeAiResultModal();
    });

    dom.aiResultModal.addEventListener('click', (event) => {
        if (event.target === dom.aiResultModal) {
            closeAiResultModal();
        }
    });

    window.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && !dom.aiResultModal.classList.contains('hidden')) {
            closeAiResultModal();
        }
    });

    dom.snippetsList.addEventListener('click', (event) => {
        const target = event.target.closest('[data-action]');
        if (!(target instanceof HTMLElement)) {
            return;
        }
        const action = target.dataset.action;
        const index = Number(target.dataset.index);
        if (Number.isNaN(index)) {
            return;
        }
        if (action === 'copy') {
            copySnippet(index);
        }
        if (action === 'edit') {
            startEditing(index);
        }
        if (action === 'delete') {
            deleteSnippet(index);
        }
        if (action === 'toggle-hidden') {
            toggleHidden(index);
        }
    });

    dom.snippetsList.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') {
            return;
        }
        const target = event.target;
        if (!(target instanceof HTMLElement) || target.dataset.action !== 'edit') {
            return;
        }
        event.preventDefault();
        const index = Number(target.dataset.index);
        if (Number.isNaN(index)) {
            return;
        }
        startEditing(index);
    });

    dom.snippetsList.addEventListener('dragstart', (event) => {
        const item = event.target.closest('.snippet-item');
        if (!(item instanceof HTMLElement)) {
            return;
        }
        const index = Number(item.dataset.index);
        if (Number.isNaN(index)) {
            return;
        }
        drag.fromIndex = index;
        drag.overIndex = null;
        drag.above = false;
        item.classList.add('is-dragging');
        if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = 'move';
            event.dataTransfer.setData('text/plain', String(index));
        }
    });

    dom.snippetsList.addEventListener('dragover', (event) => {
        if (drag.fromIndex === null) {
            return;
        }
        const item = event.target.closest('.snippet-item');
        if (!(item instanceof HTMLElement)) {
            return;
        }
        event.preventDefault();
        if (event.dataTransfer) {
            event.dataTransfer.dropEffect = 'move';
        }
        const index = Number(item.dataset.index);
        if (Number.isNaN(index)) {
            return;
        }
        const rect = item.getBoundingClientRect();
        const above = (event.clientY - rect.top) < rect.height / 2;
        if (drag.overIndex === index && drag.above === above) {
            return;
        }
        drag.overIndex = index;
        drag.above = above;
        item.parentElement?.querySelectorAll('.is-drop-above,.is-drop-below')
            .forEach((el) => el.classList.remove('is-drop-above', 'is-drop-below'));
        item.classList.add(above ? 'is-drop-above' : 'is-drop-below');
    });

    dom.snippetsList.addEventListener('dragleave', (event) => {
        if (drag.fromIndex === null || drag.overIndex === null) {
            return;
        }
        const related = event.relatedTarget;
        if (related instanceof Node && dom.snippetsList.contains(related)) {
            return;
        }
        clearDropIndicator();
    });

    dom.snippetsList.addEventListener('drop', async (event) => {
        if (drag.fromIndex === null) {
            return;
        }
        const item = event.target.closest('.snippet-item');
        if (!(item instanceof HTMLElement)) {
            clearDropIndicator();
            drag.fromIndex = null;
            return;
        }
        event.preventDefault();
        const toIndex = Number(item.dataset.index);
        if (Number.isNaN(toIndex)) {
            clearDropIndicator();
            drag.fromIndex = null;
            return;
        }
        const fromIndex = drag.fromIndex;
        const above = drag.above;
        clearDropIndicator();
        drag.fromIndex = null;
        await reorderSnippets(fromIndex, toIndex, above);
    });

    dom.snippetsList.addEventListener('dragend', () => {
        drag.fromIndex = null;
        drag.overIndex = null;
        drag.above = false;
        clearDropIndicator();
        dom.snippetsList.querySelectorAll('.is-dragging')
            .forEach((el) => el.classList.remove('is-dragging'));
    });

    window.addEventListener('swift:state-updated', (event) => {
        applyPayload(event.detail);
    });
}

function clearDropIndicator() {
    dom.snippetsList.querySelectorAll('.is-drop-above,.is-drop-below')
        .forEach((el) => el.classList.remove('is-drop-above', 'is-drop-below'));
}

wireEvents();

if (window.__devxpanderInitialState__) {
    applyPayload(window.__devxpanderInitialState__);
    delete window.__devxpanderInitialState__;
} else {
    loadInitialState();
}
