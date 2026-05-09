const dom = {
    grantPermissionButton: document.getElementById('grantPermissionButton'),
    accessibilityStatus: document.getElementById('accessibilityStatus'),
    storagePath: document.getElementById('storagePath'),
    importButton: document.getElementById('importButton'),
    exportButton: document.getElementById('exportButton'),
    snippetForm: document.getElementById('snippetForm'),
    titleInput: document.getElementById('titleInput'),
    expansionInput: document.getElementById('expansionInput'),
    saveSnippetButton: document.getElementById('saveSnippetButton'),
    cancelEditButton: document.getElementById('cancelEditButton'),
    snippetsList: document.getElementById('snippetsList'),
    flashMessage: document.getElementById('flashMessage'),
};

const state = {
    snippets: [],
    hasAccessibilityPermission: false,
    storagePath: '',
    editingOriginalTitle: null,
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
    return { title: titleValue, expansion: row.expansion ?? '' };
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
    render();
}

function render() {
    dom.accessibilityStatus.textContent = state.hasAccessibilityPermission ? 'Granted' : 'Not Granted';
    dom.storagePath.textContent = state.storagePath || 'Unknown';
    dom.cancelEditButton.classList.toggle('hidden', !state.editingOriginalTitle);
    dom.saveSnippetButton.textContent = state.editingOriginalTitle ? 'Update Snippet' : 'Save Snippet';
    renderSnippets();
}

function renderSnippets() {
    if (state.snippets.length === 0) {
        dom.snippetsList.innerHTML = '<p>No snippets yet. Add one with a menu label and text below.</p>';
        return;
    }

    const html = state.snippets.map((snippet, index) => {
        const title = escapeHtml(snippet.title ?? '');
        const expansion = escapeHtml(snippet.expansion ?? '');
        return `
            <article class="snippet-item">
                <div class="snippet-item-header">
                    <span class="snippet-title">${title}</span>
                    <div class="actions">
                        <button class="button button-secondary" type="button" data-action="edit" data-index="${index}">Edit</button>
                        <button class="button button-danger" type="button" data-action="delete" data-index="${index}">Delete</button>
                    </div>
                </div>
                <p class="snippet-expansion">${expansion}</p>
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

async function saveSnippetsToNative() {
    try {
        const payload = await sendMessageToSwift('set-snippets', {
            snippets: state.snippets.map((s) => ({ title: s.title, expansion: s.expansion })),
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
    dom.titleInput.focus();
    render();
}

async function deleteSnippet(index) {
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion }));
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

async function handleFormSubmit(event) {
    event.preventDefault();
    const title = normalizedTitle(dom.titleInput.value);
    const expansion = dom.expansionInput.value;
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
    const previousSnippets = state.snippets.map((s) => ({ title: s.title, expansion: s.expansion }));
    const previousEditing = state.editingOriginalTitle;

    if (state.editingOriginalTitle) {
        const filtered = state.snippets.filter((snippet) => snippet.title !== state.editingOriginalTitle);
        filtered.push({ title, expansion });
        state.snippets = filtered;
    }
    else {
        if (duplicateIndex >= 0) {
            showFlash('That menu label already exists. Edit it instead.', true);
            return;
        }
        state.snippets = [...state.snippets, { title, expansion }];
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

    dom.snippetForm.addEventListener('submit', (event) => {
        handleFormSubmit(event);
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

    dom.snippetsList.addEventListener('click', (event) => {
        const target = event.target;
        if (!(target instanceof HTMLElement)) {
            return;
        }
        const action = target.dataset.action;
        const index = Number(target.dataset.index);
        if (Number.isNaN(index)) {
            return;
        }
        if (action === 'edit') {
            startEditing(index);
        }
        if (action === 'delete') {
            deleteSnippet(index);
        }
    });

    window.addEventListener('swift:state-updated', (event) => {
        applyPayload(event.detail);
    });
}

wireEvents();
loadInitialState();
