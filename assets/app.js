(function () {
  "use strict";

  let wiki = window.WIKI_DATA || {
    generatedAt: "",
    categories: [],
    categoryGroups: [],
    categoryProducts: {},
    products: [],
    articles: []
  };

  const state = {
    query: "",
    category: "Alle",
    productFilter: "Alle",
    productCategoryFilter: "Alle",
    theme: readStoredTheme(),
    editorAvailable: false,
    editorRoot: "",
    showCreate: false,
    showProductCreate: false,
    editProductId: "",
    deleteProductId: "",
    permissions: [],
    roles: [],
    rolePermissions: {},
    allPermissions: [],
    expandedGroups: new Set(),
    expandedProductCategories: new Set(),
    user: null,
    setupRequired: false,
    users: [],
    usersLoading: false,
    editorDirty: false,
    dirtyGuardReturn: false,
    suggestions: [],
    suggestionsLoading: false,
    suggestionPrefill: null,
    consumeSuggestionId: "",
    consumeSuggestionSlug: "",
    rejectTarget: null,
    suggestProductId: null,
    backupBusy: false,
    backupStatus: "",
    homeCategoryFilter: "Alle",
    currentLockSlug: "",
    lockTimer: null,
    landing: true
  };

  const els = {
    meta: document.getElementById("wikiMeta"),
    search: document.getElementById("searchInput"),
    categoryNav: document.getElementById("categoryNav"),
    categoriesNav: document.getElementById("categoriesNavButton"),
    productsNav: document.getElementById("productsNavButton"),
    usersNav: document.getElementById("usersNavButton"),
    accountNav: document.getElementById("accountNavButton"),
    suggestionsNav: document.getElementById("suggestionsNavButton"),
    logout: document.getElementById("logoutButton"),
    currentUser: document.getElementById("currentUser"),
    theme: document.getElementById("themeToggleButton"),
    view: document.getElementById("view"),
    copy: document.getElementById("copyLinkButton"),
    print: document.getElementById("printButton"),
    optionsMenu: document.getElementById("optionsMenu"),
    optionsCopy: document.getElementById("optionsCopyLink"),
    optionsPrint: document.getElementById("optionsPrint"),
    optionsBackupCreate: document.getElementById("optionsBackupCreate"),
    optionsBackupRestore: document.getElementById("optionsBackupRestore")
  };

  // Feste Gruppenreihenfolge (Punkt 2): Alle zuerst, Archiv immer zuletzt.
  const GROUP_ORDER = ["Alarmtechnik", "Videotechnik", "Zutrittskontrolle", "Wiki", "Technik"];
  function groupSortIndex(name) {
    if (name === "Archiv") return 999;
    const idx = GROUP_ORDER.indexOf(name);
    if (idx >= 0) return idx;
    if (name === "Weitere Kategorien") return 50;
    return 40;
  }
  function isAdmin() {
    return Boolean(state.user && (state.user.role === "Administrator" || (can("users.manage") && can("roles.manage"))));
  }

  let articles = [];
  let bySlug = new Map();
  let categories = [];
  let categoryGroups = [];
  let products = [];
  let archivedProducts = [];
  let productById = new Map();

  const apiBase = location.protocol === "http:" || location.protocol === "https:"
    ? ""
    : "http://127.0.0.1:8765";

  function rebuildIndexes() {
    articles = [...(wiki.articles || [])].sort((a, b) => a.title.localeCompare(b.title, "de"));
    bySlug = new Map(articles.map((article) => [article.slug, article]));
    products = [...(wiki.products || [])].sort((a, b) => a.name.localeCompare(b.name, "de"));
    archivedProducts = [...(wiki.archivedProducts || [])].sort((a, b) => a.name.localeCompare(b.name, "de"));
    productById = new Map([...products, ...archivedProducts].map((product) => [product.id, product]));
    categories = buildCategories();
    categoryGroups = buildCategoryGroups();
  }

  function escapeRegex(str) {
    return String(str || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function readStoredTheme() {
    try {
      return localStorage.getItem("wiki-theme") === "dark" ? "dark" : "light";
    } catch (_) {
      return "light";
    }
  }

  function applyTheme() {
    document.documentElement.dataset.theme = state.theme;
    document.documentElement.style.colorScheme = state.theme;
    if (!els.theme) return;
    const dark = state.theme === "dark";
    els.theme.textContent = dark ? "Hell" : "Dunkel";
    els.theme.title = dark ? "Hellmodus einschalten" : "Darkmode einschalten";
    els.theme.setAttribute("aria-label", els.theme.title);
  }

  function buildCategories() {
    const names = [];
    const add = (value) => {
      const name = String(value || "").trim();
      if (name && !names.includes(name)) names.push(name);
    };

    (wiki.categories || []).forEach(add);
    articles.forEach((article) => {
      const articleCategories = article.categories && article.categories.length ? article.categories : [article.category || "Wiki Anleitung"];
      articleCategories.forEach(add);
    });
    return ["Alle", ...names];
  }

  function configuredCategories() {
    return categories.filter((category) => category !== "Alle");
  }

  function canAssignCategories() {
    return can("categories.assign") || can("categories.manage");
  }

  function categoryUsage(category) {
    const usedArticles = articles.filter((article) => !article.archived && (article.categories || [article.category]).includes(category)).map((article) => article.title);
    const usedProducts = products.filter((product) => (product.categories || []).includes(category)).map((product) => product.name);
    return { articles: usedArticles, products: usedProducts };
  }

  // Systemkategorie Archiv: nie umbenennen/loeschen/zuordnen. Sie erscheint
  // ausschließlich als eigener Navigationspunkt mit den Bereichen Artikel/Produkte.
  function manageableCategories() {
    return configuredCategories().filter((category) => category !== "Alle" && category !== "Archiv");
  }

  function buildCategoryGroups() {
    const configured = configuredCategories();
    const groups = (wiki.categoryGroups || []).map((group) => ({
      name: String(group.name || "").trim(),
      categories: (group.categories || []).filter((category) => configured.includes(category))
    })).filter((group) => group.name);

    const grouped = new Set(groups.flatMap((group) => group.categories));
    const ungrouped = configured.filter((category) => !grouped.has(category));
    if (ungrouped.length) groups.push({ name: "Weitere Kategorien", categories: ungrouped });
    groups.sort((a, b) => groupSortIndex(a.name) - groupSortIndex(b.name) || a.name.localeCompare(b.name, "de"));
    return groups;
  }

  function categoryGroupOptions(selectedGroup) {
    return categoryGroups.map((group) => {
      const selected = group.name === selectedGroup ? " selected" : "";
      return `<option value="${escapeHtml(group.name)}"${selected}>${escapeHtml(group.name)}</option>`;
    }).join("");
  }

  function activeArticles() {
    return articles.filter((article) => !article.archived);
  }

  function archivedArticles() {
    return articles.filter((article) => article.archived);
  }

  function articlesForCurrentScope() {
    if (state.category === "Archiv") return archivedArticles();
    if (state.category === "Alle") return activeArticles();
    return activeArticles().filter((article) => (article.categories || [article.category]).includes(state.category));
  }

  function categoryProductIds(categoryName) {
    const mapping = wiki.categoryProducts || {};
    return Array.isArray(mapping[categoryName]) ? mapping[categoryName] : [];
  }

  function productIdsForCategories(categoryNames) {
    const ids = [];
    (categoryNames || []).forEach((categoryName) => {
      ids.push(...categoryProductIds(categoryName));
    });
    return [...new Set(ids.filter(Boolean))];
  }

  function productLabel(productId) {
    const product = productById.get(productId);
    if (!product) return productId;
    const revision = product.hardwareRevision ? `, HW ${product.hardwareRevision}` : "";
    return `${product.name} (${product.article}${revision})`;
  }

  function isProductsPage() {
    return location.hash === "#/produkte";
  }

  function isCategoriesPage() {
    return location.hash === "#/kategorien";
  }

  function isUsersPage() {
    return location.hash === "#/benutzer";
  }

  function isAccountPage() {
    return location.hash === "#/konto";
  }

  // P9: eigenstaendige Editor-Seiten (statt Inline-Editor am Seitenende).
  function isNewArticlePage() {
    return location.hash === "#/artikel/neu";
  }

  function isEditArticlePage() {
    return /^#\/artikel\/[^/?#]+\/bearbeiten$/.test(location.hash);
  }

  function getEditSlug() {
    const match = location.hash.match(/^#\/artikel\/([^/?#]+)\/bearbeiten$/);
    return match ? decodeURIComponent(match[1]) : null;
  }

  function isEditorRoute() {
    return isNewArticlePage() || isEditArticlePage();
  }

  function isSuggestionsPage() {
    return location.hash === "#/vorschlaege";
  }

  function can(permission) {
    return state.permissions.includes(permission);
  }

  function dis(permission) {
    return can(permission) ? "" : " disabled";
  }

  function canEdit() {
    return can("articles.edit");
  }

  function canManageRoles() {
    return can("roles.manage");
  }

  function normalize(value) {
    return String(value || "")
      .toLocaleLowerCase("de")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "");
  }

  function queryTerms(value) {
    return normalize(value).trim().split(/\s+/).filter(Boolean);
  }

  function matchesSearch(value, query) {
    const normalizedQuery = normalize(query).trim();
    if (!normalizedQuery) return true;
    const haystack = normalize(value);
    const terms = queryTerms(query);
    return haystack.includes(normalizedQuery) || terms.every((term) => haystack.includes(term));
  }

  function slugify(value) {
    return normalize(value)
      .replace(/\u00e4/g, "ae")
      .replace(/\u00f6/g, "oe")
      .replace(/\u00fc/g, "ue")
      .replace(/\u00df/g, "ss")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "artikel";
  }

  function escapeHtml(value) {
    return String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function formatDate(value) {
    if (!value) return "Nicht gesetzt";
    const date = new Date(`${value}T12:00:00`);
    if (Number.isNaN(date.getTime())) return value;
    return new Intl.DateTimeFormat("de-DE", { dateStyle: "medium" }).format(date);
  }

  function articleUrl(article) {
    return `#/artikel/${article.slug}`;
  }

  function getCurrentSlug() {
    const match = location.hash.match(/^#\/artikel\/([^/?#]+)/);
    return match ? decodeURIComponent(match[1]) : null;
  }

  function setStatus(message) {
    const status = document.getElementById("editorStatus");
    if (status) status.textContent = message;
  }

  // P5: wiederverwendbarer globaler Save-Zustand. markSaveBusy sichert den
  // ausloesenden Button eines Speicher-Formulars, deaktiviert ihn und zeigt
  // eine Ladeanimation; unmarkSaveBusy stellt ihn wieder her (immer im
  // finally aufrufen, damit er auch bei Fehlern klickbar wird).
  const SAVE_FORM_IDS = new Set([
    "setupForm", "loginForm", "articleForm", "editArticleForm", "deleteArticleForm",
    "restoreArticleForm", "requestDeleteForm", "suggestArticleForm", "productForm",
    "editProductForm", "deleteProductForm", "groupForm", "subcategoryForm", "newUserForm", "rolesForm",
    "newRoleForm", "accountNameForm", "accountPasswordForm", "inlineProductForm"
  ]);

  function isSaveForm(form) {
    if (!form || !form.matches) return false;
    if (form.id && SAVE_FORM_IDS.has(form.id)) return true;
    return form.matches("[data-user-form], [data-group-manage-form], [data-restore-product-form], [data-request-delete-product-form], [data-suggest-product-form], [data-reject-form]");
  }

  function markSaveBusy(event) {
    try {
      const form = event.target;
      if (!isSaveForm(form)) return null;
      const direct = event.submitter && event.submitter instanceof HTMLButtonElement ? event.submitter : null;
      const button = direct || form.querySelector('button[type="submit"], button.primary-button, button.danger-button');
      if (!button || button.disabled) return null;
      button.disabled = true;
      button.classList.add("is-saving");
      return button;
    } catch (_) { return null; }
  }

  function unmarkSaveBusy(button) {
    try {
      if (!button) return;
      button.classList.remove("is-saving");
      button.disabled = false;
    } catch (_) { /* Button evtl. nicht mehr im DOM. */ }
  }

  // Gleiches Muster fuer Speicheraktionen ausserhalb von Formularen
  // (z. B. Uebernehmen/Ablehnen auf der Review-Seite).
  async function runSaveAction(button, fn) {
    if (button) {
      button.disabled = true;
      button.classList.add("is-saving");
    }
    try {
      return await fn();
    } finally {
      unmarkSaveBusy(button);
    }
  }

  async function apiRequest(path, options) {
    const response = await fetch(`${apiBase}${path}`, {
      headers: { "Content-Type": "application/json" },
      ...options
    });
    const data = await response.json();
    if (response.status === 401) {
      state.user = null;
      state.editorAvailable = false;
      state.permissions = [];
      state.roles = [];
      state.rolePermissions = {};
      state.suggestions = [];
      state.suggestionsLoading = false;
      state.suggestionPrefill = null;
      state.consumeSuggestionId = "";
      state.consumeSuggestionSlug = "";
      state.rejectTarget = null;
      state.suggestProductId = null;
      state.usersLoading = false;
      renderAuth();
    }
    if (!response.ok) throw new Error(data.error || "Aktion fehlgeschlagen.");
    return data;
  }

  function fileToPayload(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const result = String(reader.result || "");
        resolve({
          name: file.name,
          type: file.type,
          data: result.includes(",") ? result.split(",")[1] : result
        });
      };
      reader.onerror = () => reject(reader.error || new Error("Datei konnte nicht gelesen werden."));
      reader.readAsDataURL(file);
    });
  }

  async function filesToPayload(files) {
    return Promise.all(Array.from(files || []).map(fileToPayload));
  }

  function selectedExistingAttachments(form) {
    return Array.from(form.querySelectorAll("input[name='existingAttachment']:checked")).map((input) => {
      const [path, name] = input.value.split("|");
      return { path, name: name || path.split("/").pop() };
    });
  }

  async function uploadEditorImage(editor, file) {
    if (!can("articles.edit") || !file) return;
    const form = editor.closest("form");
    const titleInput = form ? form.elements.title : null;
    const currentSlug = form?.dataset?.slug || getCurrentSlug() || slugify(titleInput?.value || "bilder");
    const payload = await fileToPayload(file);
    const data = await apiRequest("/api/uploads", {
      method: "POST",
      body: JSON.stringify({ articleSlug: currentSlug, files: [payload] })
    });
    const saved = data.files && data.files[0];
    if (!saved) throw new Error("Bild konnte nicht gespeichert werden.");
    const width = window.prompt("Bildbreite in Pixeln", "420") || "420";
    const textarea = editor.querySelector("[data-markdown-input]");
    if (textarea) {
      const markdown = imageMarkdown(saved.path, saved.name, width, "");
      textarea.setRangeText(markdown + "\n", textarea.selectionStart, textarea.selectionEnd, "end");
      textarea.focus();
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
      // Neu eingefügtes Bild sofort selektieren + Handles zeigen.
      try {
        const visual = editor.querySelector("[data-visual-input]");
        const fresh = visual ? visual.querySelector(`img[src="${saved.path.replace(/"/g, "")}"]`) : null;
        if (fresh) showImageOverlay(fresh);
      } catch (_) { /* Selektion ist optional */ }
    }
  }

  async function refreshFromServer(data) {
    wiki = data || await apiRequest("/api/wiki-data");
    rebuildIndexes();
    if (!categories.includes(state.category)) state.category = "Alle";
    if (wiki.generatedAt) els.meta.textContent = `Stand ${formatDate(wiki.generatedAt.slice(0, 10))}`;
    render();
  }

  async function detectEditor() {
    try {
      const response = await fetch(`${apiBase}/api/status`, { cache: "no-store" });
      if (!response.ok) return;
      const data = await response.json();
      state.setupRequired = Boolean(data.setupRequired);
      state.user = data.user || null;
      state.permissions = Array.isArray(data.permissions) ? data.permissions : [];
      state.editorAvailable = Boolean(data.editor);
      updateAccountUi();
      if (state.user) {
        if (canManageRoles() || can("users.manage")) await loadRoles().catch(() => {});
        await refreshFromServer();
        await loadSuggestions().catch(() => { state.suggestions = []; });
      }
      else renderAuth();
    } catch (_) {
      state.editorAvailable = false;
    }
    if (state.user) render();
  }

  function updateAccountUi() {
    document.body.classList.toggle("auth-pending", !state.user);
    if (els.currentUser) {
      els.currentUser.hidden = !state.user;
      els.currentUser.textContent = state.user ? `${state.user.displayName || state.user.username} · ${state.user.role}` : "";
    }
    if (els.logout) els.logout.hidden = !state.user;
    if (els.usersNav) els.usersNav.hidden = !(state.user && can("users.manage"));
    if (els.accountNav) els.accountNav.hidden = !state.user;
    // P3 Leserrolle: Kategorien/Produkte nur mit entsprechendem Recht sichtbar.
    const productPerms = ["products.view", "products.create", "products.edit", "products.delete", "products.archive"];
    if (els.categoriesNav) els.categoriesNav.hidden = !(state.user && (can("categories.manage") || can("articles.create") || can("articles.edit")));
    if (els.productsNav) els.productsNav.hidden = !(state.user && productPerms.some((permission) => can(permission)));
    if (els.suggestionsNav) {
      const show = Boolean(state.user && (can("articles.suggest") || can("articles.edit")));
      els.suggestionsNav.hidden = !show;
      // Ampel aus Serverstatus (state.suggestions = GET /api/suggestions):
      // Rot = mind. ein offener (Warten auf Freigabe), Gruen = nur bearbeitete
      // (warten auf Abschluss), sonst normal. Gilt fuer alle Rollen.
      const mine = Array.isArray(state.suggestions) ? state.suggestions : [];
      const openCount = mine.filter((entry) => (entry.status || "open") === "open").length;
      const processedCount = mine.filter((entry) => (entry.status || "") === "accepted" || (entry.status || "") === "rejected").length;
      els.suggestionsNav.textContent = (openCount || processedCount) ? `Vorschläge (${openCount || processedCount})` : "Vorschläge";
      els.suggestionsNav.classList.toggle("has-open-suggestions", Boolean(show && openCount > 0));
      els.suggestionsNav.classList.toggle("has-processed-suggestions", Boolean(show && openCount === 0 && processedCount > 0));
    }
    // Punkte 11/12: Optionen-Menü statt direkter Link/Druck-Buttons.
    if (els.optionsMenu) els.optionsMenu.hidden = !state.user;
    if (els.optionsBackupCreate) els.optionsBackupCreate.hidden = !isAdmin();
    if (els.optionsBackupRestore) els.optionsBackupRestore.hidden = !isAdmin();
  }

  function renderAuth(message) {
    document.body.classList.add("auth-pending");
    const setup = state.setupRequired;
    els.view.innerHTML = `<section class="auth-panel">
      <img src="assets/wissensdatenbank-logo.png" alt="Wissensdatenbank des Technischen Supports">
      <form id="${setup ? "setupForm" : "loginForm"}" class="auth-form">
        <h1>${setup ? "Administrator einrichten" : "Anmelden"}</h1>
        <p>${setup ? "Lege das erste Administratorkonto an. Es gibt kein voreingestelltes Passwort." : "Melde dich mit deinem Wiki-Konto an."}</p>
        ${message ? `<p class="editor-notice">${escapeHtml(message)}</p>` : ""}
        <label><span>Benutzername</span><input name="username" autocomplete="username" required minlength="3"></label>
        <label><span>Passwort</span><input name="password" type="password" autocomplete="${setup ? "new-password" : "current-password"}" required minlength="10"></label>
        ${setup ? `<label><span>Passwort wiederholen</span><input name="passwordRepeat" type="password" autocomplete="new-password" required minlength="10"></label>` : ""}
        <button class="primary-button" type="submit">${setup ? "Administratorkonto anlegen" : "Anmelden"}</button>
      </form>
    </section>`;
  }

  function filteredArticles() {
    const query = normalize(state.query).trim();
    const terms = queryTerms(state.query);
    const source = query
      ? (state.category === "Archiv" ? archivedArticles() : activeArticles())
      : articlesForCurrentScope();
    return source
      .filter((article) => state.productFilter === "Alle" || (article.products || []).includes(state.productFilter))
      .filter((article) => {
        if (!query) return true;
        const productText = (article.products || []).map(productLabel).join(" ");
        const haystack = normalize([
          article.title,
          article.summary,
          (article.categories || [article.category]).join(" "),
          article.tags.join(" "),
          productText,
          article.searchText
        ].join(" "));
        return haystack.includes(query) || terms.every((term) => haystack.includes(term));
      })
      .sort((a, b) => {
        if (!query) return a.title.localeCompare(b.title, "de");
        const aTitleText = normalize(a.title);
        const bTitleText = normalize(b.title);
        const aTitle = aTitleText.includes(query) || terms.some((term) => aTitleText.includes(term)) ? 0 : 1;
        const bTitle = bTitleText.includes(query) || terms.some((term) => bTitleText.includes(term)) ? 0 : 1;
        return aTitle - bTitle || a.title.localeCompare(b.title, "de");
      });
  }

  // P6/P7: erlaubte Inline-Styles (Schriftfarbe/-groesse) als reversibles
  // HTML-in-Markdown. Nur color/font-size mit sicheren Werten passieren,
  // alles andere wird wie normaler Text escapet (XSS-Schutz).
  function sanitizeSpanStyle(style) {
    const out = [];
    String(style || "").split(";").forEach((declaration) => {
      const colon = declaration.indexOf(":");
      if (colon < 0) return;
      const property = declaration.slice(0, colon).trim().toLowerCase();
      const value = declaration.slice(colon + 1).trim();
      if (!value || /["<>]/.test(value)) return;
      if (property === "color" && /^(#[0-9a-f]{3,8}|rgba?\([^)]*\)|[a-z]+)$/i.test(value)) out.push(`color: ${value}`);
      if (property === "font-size" && /^(\d+(\.\d+)?(rem|px|em|%)|small|medium|large|x-small|x-large|xx-small|xx-large|smaller|larger)$/i.test(value)) out.push(`font-size: ${value}`);
    });
    return out.join("; ");
  }

  // Blockmarker (-, *, +, 1.) und Ueberschriften/Zitate koennen im
  // Visual-Editor innerhalb eines Inline-Style-Spans stehen. Diese Helfer
  // trennen die fuehrenden Oeffnungs-Spans ab, damit der Marker wieder am
  // Zeilenanfang erkannt wird und die Formatierung um den Inhalt erhalten
  // bleibt. Normale Bindestriche im Fliesstext werden nicht angetastet.
  function splitLeadingSpans(line) {
    const match = String(line || "").match(/^\s*((?:<span\s+style="[^"]*"\s*>)*)(.*)$/i);
    if (!match) return { spans: "", rest: String(line || "") };
    return { spans: match[1], rest: match[2] };
  }

  function extractListLine(line) {
    const leading = splitLeadingSpans(line);
    const ordered = leading.rest.match(/^\s*(\d+)([.)])\s+(.+)$/);
    if (ordered) return { type: "ol", content: leading.spans + ordered[3] };
    const unordered = leading.rest.match(/^\s*([-*+])\s+(.+)$/);
    if (unordered) return { type: "ul", content: leading.spans + unordered[2] };
    return null;
  }

  function extractHeadingLine(line) {
    const leading = splitLeadingSpans(line);
    const match = leading.rest.match(/^\s*(#{1,6})\s+(.+)$/);
    if (!match) return null;
    return { level: Math.min(match[1].length, 6), content: leading.spans + match[2] };
  }

  function extractQuoteLine(line) {
    const leading = splitLeadingSpans(line);
    const match = leading.rest.match(/^\s*>\s+(.+)$/);
    if (!match) return null;
    return { content: leading.spans + match[1] };
  }

  function normalizeBlockMarkers(content) {
    return String(content || "").split("\\\n").map((line) => {
      const leading = splitLeadingSpans(line);
      const list = leading.rest.match(/^([-*+]|\d+[.)])\s+(.+)$/);
      if (list) return `${list[1]} ${leading.spans}${list[2]}`;
      const heading = leading.rest.match(/^(#{1,6})\s+(.+)$/);
      if (heading) return `${heading[1]} ${leading.spans}${heading[2]}`;
      const quote = leading.rest.match(/^>\s+(.+)$/);
      if (quote) return `> ${leading.spans}${quote[1]}`;
      return line;
    }).join("\\\n");
  }

  function parseImageAttrs(attrText) {
    const attrs = { width: "", caption: "" };
    if (!attrText) return attrs;
    const w = String(attrText).match(/width\s*=\s*([0-9]+)/);
    if (w) attrs.width = w[1];
    // attrText ist bereits HTML-escapet: Anfuehrungszeichen stehen als &quot; da.
    const c = String(attrText).match(/caption\s*=\s*(?:"([^"]*)"|&quot;(.*?)&quot;)/);
    if (c) attrs.caption = c[1] !== undefined ? c[1] : (c[2] || "");
    return attrs;
  }

  function imageMarkdown(src, alt, width, caption) {
    const w = width ? `{width=${width}${caption ? ` caption="${String(caption).replace(/"/g, "'")}"` : ""}}` : (caption ? `{caption="${String(caption).replace(/"/g, "'")}"}` : "");
    return `![${alt || "Bild"}](${src})${w}`;
  }

  function inlineMarkdownCore(value) {
    let text = escapeHtml(value);
    // Punkt 7/8: Bild mit optionaler Breite + Beschriftung -> figure/figcaption.
    text = text.replace(/!\[([^\]]*)\]\(([^)]+)\)(?:\{([^}]*)\})?/g, (_match, alt, src, attrText) => {
      const attrs = parseImageAttrs(attrText || "");
      const bounded = attrs.width ? Math.min(Math.max(Number(attrs.width), 80), 1200) : "";
      const style = bounded ? ` style="width: ${bounded}px; max-width: 100%;"` : "";
      const resizeAttr = ` data-img-resize="true"${bounded ? ` data-img-width="${bounded}"` : ` data-img-width="420"`}`;
      const img = `<img src="${src}" alt="${alt || "Bild"}"${style}${resizeAttr} class="editable-img">`;
      if (attrs.caption) return `<figure class="wiki-figure">${img}<figcaption contenteditable="true">${attrs.caption}</figcaption></figure>`;
      return img;
    });
    text = text.replace(/`([^`]+)`/g, "<code>$1</code>");
    text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    text = text.replace(/\*([^*]+)\*/g, "<em>$1</em>");
    text = text.replace(/~~([^~]+)~~/g, "<s>$1</s>");
    text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
    return text;
  }

  function inlineMarkdown(value) {
    const text = String(value || "");
    if (!/<span|<\/span/i.test(text)) return inlineMarkdownCore(text);
    // Span-Tags vor der Inline-Markdown-Verarbeitung durch Platzhalter
    // ersetzen, damit **fett** / ~~weg~~ auch ueber Span-Grenzen hinweg
    // funktionieren (z.B. kombinierte Farbe + Fettung).
    const tokens = [];
    const stack = [];
    const nonce = `__WIKI_SPAN_${Math.random().toString(36).slice(2)}_`;
    const placeholder = (index) => `${nonce}${index}__`;
    const protectedText = text.replace(/<span\s+style="([^"]*)"\s*>|<\/span\s*>/gi, (_match, style) => {
      if (style !== undefined) {
        const clean = sanitizeSpanStyle(style);
        if (!clean) {
          stack.push(false);
          return "";
        }
        tokens.push(`<span style="${escapeHtml(clean)}">`);
        stack.push(true);
        return placeholder(tokens.length - 1);
      }
      if (!stack.length) return "";
      if (!stack.pop()) return "";
      tokens.push("</span>");
      return placeholder(tokens.length - 1);
    });
    let result = inlineMarkdownCore(protectedText);
    const placeholderPattern = new RegExp(`${nonce}\\d+__`, "g");
    result = result.split(/(<[^>]*>)/).map((part) => {
      if (part.startsWith("<") && part.endsWith(">")) {
        return part.replace(placeholderPattern, "");
      }
      let restored = part;
      tokens.forEach((token, index) => {
        restored = restored.split(placeholder(index)).join(token);
      });
      return restored;
    }).join("");
    for (let i = stack.length - 1; i >= 0; i -= 1) {
      if (stack[i]) result += "</span>";
    }
    return result;
  }

  function splitTableRow(line) {
    return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim());
  }

  function markdownToHtml(markdown) {
    const lines = String(markdown || "").split(/\r?\n/);
    const html = [];
    let inUl = false;
    let inOl = false;
    let inCode = false;
    let pendingBr = false;

    const closeLists = () => {
      if (inUl) { html.push("</ul>"); inUl = false; }
      if (inOl) { html.push("</ol>"); inOl = false; }
    };

    for (let i = 0; i < lines.length; i += 1) {
      let line = lines[i];
      // P7: Backslash am Zeilenende = harter Umbruch (Round-Trip mit <br>).
      let hardBreak = false;
      if (!inCode && /\\\s*$/.test(line)) {
        line = line.replace(/\\\s*$/, "");
        hardBreak = true;
      }

      if (/^\s*```/.test(line)) {
        closeLists();
        pendingBr = false;
        html.push(inCode ? "</code></pre>" : "<pre><code>");
        inCode = !inCode;
        continue;
      }

      if (inCode) {
        pendingBr = false;
        html.push(escapeHtml(line));
        continue;
      }

      if (line.includes("|") && lines[i + 1] && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[i + 1])) {
        closeLists();
        pendingBr = false;
        const headers = splitTableRow(line);
        const bodyRows = [];
        i += 2;
        while (i < lines.length && lines[i].includes("|") && lines[i].trim()) {
          bodyRows.push(splitTableRow(lines[i]));
          i += 1;
        }
        i -= 1;
        html.push(`<table><thead><tr>${headers.map((cell) => `<th>${inlineMarkdown(cell)}</th>`).join("")}</tr></thead><tbody>`);
        bodyRows.forEach((row) => {
          html.push(`<tr>${row.map((cell) => `<td>${inlineMarkdown(cell)}</td>`).join("")}</tr>`);
        });
        html.push("</tbody></table>");
        continue;
      }

      if (!line.trim()) {
        closeLists();
        pendingBr = false;
        continue;
      }

      const heading = extractHeadingLine(line);
      if (heading) {
        closeLists();
        pendingBr = false;
        html.push(`<h${heading.level}>${inlineMarkdown(heading.content)}</h${heading.level}>`);
        continue;
      }

      const listLine = extractListLine(line);
      if (listLine && listLine.type === "ul") {
        pendingBr = false;
        if (inOl) { html.push("</ol>"); inOl = false; }
        if (!inUl) { html.push("<ul>"); inUl = true; }
        html.push(`<li>${inlineMarkdown(listLine.content)}</li>`);
        continue;
      }

      if (listLine && listLine.type === "ol") {
        pendingBr = false;
        if (inUl) { html.push("</ul>"); inUl = false; }
        if (!inOl) { html.push("<ol>"); inOl = true; }
        html.push(`<li>${inlineMarkdown(listLine.content)}</li>`);
        continue;
      }

      const quote = extractQuoteLine(line);
      if (quote) {
        closeLists();
        pendingBr = false;
        html.push(`<blockquote>${inlineMarkdown(quote.content)}</blockquote>`);
        continue;
      }

      closeLists();
      if (pendingBr && html.length && /^<p>.*<\/p>$/.test(html[html.length - 1])) {
        html[html.length - 1] = html[html.length - 1].replace(/<\/p>$/, `<br>${inlineMarkdown(line)}</p>`);
      } else {
        html.push(`<p>${inlineMarkdown(line)}</p>`);
      }
      pendingBr = hardBreak;
    }

    closeLists();
    if (inCode) html.push("</code></pre>");
    return html.join("\n") || "<p class=\"muted-text\">Vorschau erscheint hier.</p>";
  }

  function renderNavigation() {
    if (els.categoriesNav) els.categoriesNav.classList.toggle("is-active", isCategoriesPage());
    if (els.productsNav) els.productsNav.classList.toggle("is-active", isProductsPage());
    if (els.usersNav) els.usersNav.classList.toggle("is-active", isUsersPage());
    if (els.suggestionsNav) els.suggestionsNav.classList.toggle("is-active", isSuggestionsPage());
    const categoryButton = (category) => {
      const active = category === state.category ? " is-active" : "";
      const count = category === "Alle"
        ? activeArticles().length
        : category === "Archiv"
          ? archivedArticles().length + archivedProducts.length
          : activeArticles().filter((article) => (article.categories || [article.category]).includes(category)).length;
      return `<button class="category-button${active}" type="button" data-category="${escapeHtml(category)}">
        <span>${escapeHtml(category)}</span>
        <small>${count}</small>
      </button>`;
    };

    els.categoryNav.innerHTML = [
      categoryButton("Alle"),
      ...categoryGroups.map((group) => {
        const expanded = state.expandedGroups.has(group.name);
        const visibleCategories = (group.categories || []).filter((category) => category !== "Archiv");
        const total = visibleCategories.reduce((sum, category) => {
          return sum + activeArticles().filter((article) => (article.categories || [article.category]).includes(category)).length;
        }, 0);
        return `<div class="category-group${expanded ? " is-open" : ""}">
          <button class="category-group-toggle" type="button" data-toggle-group="${escapeHtml(group.name)}" aria-expanded="${expanded}">
            <span>${escapeHtml(group.name)}</span>
            <small>${total}</small>
          </button>
          <div class="category-group-items">
            ${expanded ? visibleCategories.map(categoryButton).join("") : ""}
          </div>
        </div>`;
      }),
      ...((archivedArticles().length || archivedProducts.length) ? [categoryButton("Archiv")] : [])
    ].join("");

  }

  function metaTable(article) {
    const articleProducts = can("products.view") ? ((article.products || []).map(productLabel).join(", ") || "Nicht zugeordnet") : "–";
    const articleCategories = (article.categories || [article.category]).filter(Boolean).join(", ") || "Ohne Kategorie";
    return `<dl class="meta-grid">
      <div><dt>Kategorien</dt><dd>${escapeHtml(articleCategories)}</dd></div>
      <div><dt>Produkte</dt><dd>${escapeHtml(articleProducts)}</dd></div>
      <div><dt>Status</dt><dd>${escapeHtml(article.status || "Entwurf")}</dd></div>
      <div><dt>Revision</dt><dd>${escapeHtml(article.revision || 1)}</dd></div>
      <div><dt>Aktualisiert</dt><dd>${escapeHtml(formatDate(article.updated))}</dd></div>
      <div><dt>Verantwortlich</dt><dd>${escapeHtml(article.owner || "Nicht gesetzt")}</dd></div>
      <div><dt>Letzte Aktion</dt><dd>${escapeHtml(article.changeAction || "Nicht gesetzt")}</dd></div>
      <div class="meta-wide"><dt>Letzter Grund</dt><dd>${escapeHtml(article.changeReason || "Nicht gesetzt")}</dd></div>
    </dl>`;
  }

  function tagList(tags) {
    if (!tags || !tags.length) return "";
    return `<div class="tag-list">${tags.map((tag) => `<span>${escapeHtml(tag)}</span>`).join("")}</div>`;
  }

  function renderAttachments(attachments) {
    if (!attachments || !attachments.length) return "";
    return `<section class="attachments-section">
      <h2>Anhaenge</h2>
      <div class="attachment-links">
        ${attachments.map((attachment) => `
          <a href="${escapeHtml(attachment.path)}" target="_blank" rel="noreferrer">${escapeHtml(attachment.name || attachment.path)}</a>
        `).join("")}
      </div>
    </section>`;
  }

  function tocList(items) {
    if (!items.length) {
      return `<div class="empty-state">
        <h2>Keine Artikel</h2>
        <p>In dieser Auswahl ist noch kein Artikel vorhanden.</p>
      </div>`;
    }

    return `<div class="toc-list">${items.map((article, index) => `
      <article class="toc-item${article.archived ? " is-archived" : ""}">
        <span class="toc-number">${index + 1}</span>
        <a class="toc-main" href="${articleUrl(article)}">
          <strong>${escapeHtml(article.title)}</strong>
        </a>
        <span class="toc-products">${can("products.view") ? tocProductLabels(article) : ""}</span>
        <span class="toc-meta">Rev. ${escapeHtml(article.revision || 1)}<br>${escapeHtml(formatDate(article.updated))}</span>
      </article>
    `).join("")}</div>`;
  }

  function tocProductLabels(article) {
    const articleProducts = (article.products || []).map((productId) => productById.get(productId)).filter(Boolean);
    if (!articleProducts.length) return `<small>Keine Produkte zugeordnet</small>`;
    const productChip = (product) => `<span>${escapeHtml(product.name)}${product.article ? ` · ${escapeHtml(product.article)}` : ""}</span>`;
    if (articleProducts.length === 1) return productChip(articleProducts[0]);
    return `${productChip(articleProducts[0])}<details class="toc-more-products">
      <summary title="Weitere verknuepfte Produkte anzeigen" aria-label="Weitere verknuepfte Produkte anzeigen">…</summary>
      <div>${articleProducts.slice(1).map(productChip).join("")}</div>
    </details>`;
  }

  function categoryOptions(selectedCategory) {
    return configuredCategories()
      .filter((category) => category !== "Archiv")
      .map((category) => {
        const selected = category === selectedCategory ? " selected" : "";
        return `<option value="${escapeHtml(category)}"${selected}>${escapeHtml(category)}</option>`;
      }).join("");
  }

  function dropdownLabel(values, fallback) {
    if (!values || !values.length) return fallback;
    if (values.length <= 2) return values.join(", ");
    return `${values.length} ausgewaehlt`;
  }

  function updateMultiSelectSummary(dropdown, fallback, labeler) {
    if (!dropdown) return;
    const selected = Array.from(dropdown.querySelectorAll("input:checked")).map((input) => labeler ? labeler(input.value) : input.value);
    const summary = dropdown.querySelector("summary");
    if (summary) summary.textContent = dropdownLabel(selected, fallback);
  }

  function filterMultiSelectOptions(searchInput) {
    const dropdown = searchInput.closest(".multi-select");
    if (!dropdown) return;
    const query = searchInput.value;
    dropdown.querySelectorAll("[data-filterable-option]").forEach((option) => {
      const searchable = option.dataset.search || option.textContent || "";
      option.classList.toggle("is-filtered-out", !matchesSearch(searchable, query));
    });
  }

  function articleCategoryDropdown(selectedCategories, disabled) {
    const selected = new Set(selectedCategories || []);
    const label = dropdownLabel([...selected], "Kategorien auswaehlen");
    const items = configuredCategories().filter((category) => category !== "Archiv");
    return `<details class="multi-select" data-article-category-dropdown>
      <summary>${escapeHtml(label)}</summary>
      <div class="multi-select-menu">
        <input class="multi-select-search" type="search" autocomplete="off" placeholder="Kategorien suchen"${disabled} data-multi-select-search>
        ${items.map((category) => `
          <label class="check-option" data-filterable-option data-search="${escapeHtml(category)}">
            <input type="checkbox" value="${escapeHtml(category)}" data-article-category${selected.has(category) ? " checked" : ""}${disabled}>
            <span>${escapeHtml(category)}</span>
          </label>
        `).join("")}
      </div>
    </details>`;
  }

  function productsForCategories(categoryNames) {    // Punkt 3: Nur Produkte, die mindestens einer der gewählten Kategorien zugeordnet sind.
    // Produkte ohne Kategorienzuordnung bleiben nur sichtbar, wenn keine Kategorie gewählt ist.
    const selected = (categoryNames || []).filter(Boolean);
    if (!selected.length) return [...products];
    const wanted = new Set(selected);
    const matched = products.filter((product) => (product.categories || []).some((cat) => wanted.has(cat)));
    // Fallback über categoryProducts-Mapping (falls Produkt-Kategorien leer, aber Mapping gesetzt).
    const mappedIds = new Set(productIdsForCategories(selected));
    const mapped = products.filter((product) => mappedIds.has(product.id));
    const merged = new Map();
    [...matched, ...mapped].forEach((product) => merged.set(product.id, product));
    return [...merged.values()].sort((a, b) => a.name.localeCompare(b.name, "de"));
  }

  function relatedCandidates(currentSlug, categoryNames) {
    // Punkt 4: nur Artikel derselben Kategorie, nie der Artikel selbst.
    const selected = (categoryNames || []).filter(Boolean);
    return [...articles]
      .filter((article) => !article.archived && article.slug !== currentSlug)
      .filter((article) => {
        if (!selected.length) return true;
        const cats = article.categories && article.categories.length ? article.categories : [article.category];
        return cats.some((cat) => selected.includes(cat));
      })
      .sort((a, b) => a.title.localeCompare(b.title, "de"));
  }

  function refreshCategoryDependentFields(form, currentSlug) {
    if (!form) return;
    const selectedCategories = Array.from(form.querySelectorAll("[data-article-category]:checked")).map((input) => input.value);
    const keptProducts = Array.from(form.querySelectorAll("[data-article-product]:checked")).map((input) => input.value);
    const keptRelated = Array.from(form.querySelectorAll("[data-related-article]:checked")).map((input) => input.value);
    // Produkte: Auswahl auf sichtbare einschränken, unpassende abwählen + Hinweis.
    const visibleIds = new Set(productsForCategories(selectedCategories).map((p) => p.id));
    const validProducts = keptProducts.filter((id) => visibleIds.has(id));
    const removedProducts = keptProducts.filter((id) => !visibleIds.has(id));
    const field = form.querySelector("[data-article-products-field]");
    if (field) {
      const disabled = field.querySelector("[data-article-product]")?.disabled ? " disabled" : "";
      field.innerHTML = `<div class="field-heading"><span>Produkte fuer diesen Artikel</span><button class="secondary-button compact-button" type="button" data-open-inline-product${disabled}>Neues Produkt anlegen</button></div>`
        + articleProductCheckboxes(validProducts, disabled, selectedCategories)
        + (removedProducts.length ? `<p class="editor-notice">${removedProducts.length} Produkt(e) entfernt – passt nicht zur neuen Kategorie: ${removedProducts.map((id) => escapeHtml(productLabel(id))).join(", ")}</p>` : "")
        + `<small class="muted-text">Nur Produkte der gewaehlten Kategorie.</small>`;
    }
    // Verwandte: kategorie-fremde behalten (sichtbar markiert), Liste neu filtern.
    const relatedHost = form.querySelector("[data-related-dropdown]")?.closest(".field-block");
    if (relatedHost) {
      const disabled = relatedHost.querySelector("[data-related-article]")?.disabled ? " disabled" : "";
      relatedHost.outerHTML = relatedArticleCheckboxes(currentSlug, keptRelated, disabled, selectedCategories);
    }
    if (removedProducts.length) setStatus(`${removedProducts.length} Produkt(e) wegen Kategoriewechsel entfernt.`);
  }

  function validateCategoryProducts(selectedCategories, selectedProducts) {
    const visible = new Set(productsForCategories(selectedCategories).map((p) => p.id));
    return (selectedProducts || []).filter((id) => !visible.has(id));
  }

  function articleProductDropdown(selectedIds, disabled, categoryNames) {
    const selected = new Set(selectedIds || []);
    const selectedLabels = [...selected].map(productLabel);
    const label = dropdownLabel(selectedLabels, "Produkte auswaehlen");
    const visible = categoryNames ? productsForCategories(categoryNames) : [...products];
    if (!products.length) return `<p class="editor-notice">Lege zuerst ein Produkt im Menuepunkt Produkte an.</p>`;
    if (categoryNames && !visible.length) return `<p class="editor-notice">Keine Produkte fuer die gewaehlte Kategorie vorhanden.</p><details class="multi-select" data-article-product-dropdown hidden><summary></summary></details>`;
    return `<details class="multi-select" data-article-product-dropdown>
      <summary>${escapeHtml(label)}</summary>
      <div class="multi-select-menu">
        <input class="multi-select-search" type="search" autocomplete="off" placeholder="Produkte suchen"${disabled} data-multi-select-search>
        ${visible.map((product) => `
          <label class="check-option" data-filterable-option data-search="${escapeHtml(productLabel(product.id))}">
            <input type="checkbox" value="${escapeHtml(product.id)}" data-article-product${selected.has(product.id) ? " checked" : ""}${disabled}>
            <span>${escapeHtml(productLabel(product.id))}</span>
          </label>
        `).join("")}
      </div>
    </details>`;
  }

  function productOptionsForCategory(category, selectedProduct) {
    // Punkt 10: Produktfilter zeigt nur Produkte der gewählten Kategorie (kaskadierend).
    const list = (!category || category === "Alle") ? [...products] : productsForCategories([category]);
    const options = [`<option value="Alle"${selectedProduct === "Alle" ? " selected" : ""}>Alle Produkte</option>`]
      .concat(list.map((product) => {
        const selected = product.id === selectedProduct ? " selected" : "";
        return `<option value="${escapeHtml(product.id)}"${selected}>${escapeHtml(productLabel(product.id))}</option>`;
      }));
    // Falls gespeicherter Produktfilter nicht mehr zur Kategorie passt, trotzdem anzeigen.
    if (selectedProduct && selectedProduct !== "Alle" && !list.some((p) => p.id === selectedProduct) && productById.has(selectedProduct)) {
      options.push(`<option value="${escapeHtml(selectedProduct)}" selected>${escapeHtml(productLabel(selectedProduct))} (andere Kategorie)</option>`);
    }
    return options.join("");
  }

  function productOptions(selectedProduct) {
    return productOptionsForCategory("Alle", selectedProduct);
  }

  function categoryFilterOptions(selectedCategory) {
    return [`<option value="Alle"${selectedCategory === "Alle" ? " selected" : ""}>Alle Produktgruppen</option>`]
      .concat(configuredCategories().filter((category) => category !== "Archiv").map((category) => {
        const selected = category === selectedCategory ? " selected" : "";
        return `<option value="${escapeHtml(category)}"${selected}>${escapeHtml(category)}</option>`;
      })).join("");
  }

  // Produkte -> Kategorieauswahl: drei feste Hauptbereiche, Produktgruppen
  // immer dynamisch aus der echten Zuordnung (categoryGroups). Keine statischen
  // Produktgruppen im Frontend. Speichern unverändert über data-product-category.
  const PRODUCT_CATEGORY_PARENTS = ["Alarmtechnik", "Videotechnik", "Zutrittskontrolle"];

  function productCategorySubCheckboxes(categories, selected, disabled) {
    return `<div class="check-grid">${categories.map((category) => `
      <label class="check-option">
        <input type="checkbox" value="${escapeHtml(category)}" data-product-category${selected.has(category) ? " checked" : ""}${disabled}>
        <span>${escapeHtml(category)}</span>
      </label>
    `).join("")}</div>`;
  }

  function productCategoryAccordion(selectedCategories, disabled) {
    const selected = new Set(selectedCategories || []);
    const manageable = new Set(manageableCategories());
    const groupsByName = new Map(managedCategoryGroups().map((group) => [group.name, group.categories || []]));
    const shown = new Set();
    const sections = PRODUCT_CATEGORY_PARENTS.map((parent) => {
      const subs = (groupsByName.get(parent) || [])
        .filter((category) => category !== "Archiv" && !PRODUCT_CATEGORY_PARENTS.includes(category) && manageable.has(category));
      subs.forEach((category) => shown.add(category));
      const selectedHere = subs.filter((category) => selected.has(category));
      const body = subs.length
        ? productCategorySubCheckboxes(subs, selected, disabled)
        : `<p class="muted-text">Noch keine Produktgruppen zugeordnet – siehe „Zuordnung verwalten".</p>`;
      return `<details class="product-category-accordion"${selectedHere.length ? " open" : ""}>
        <summary><span>${escapeHtml(parent)}</span><small>${selectedHere.length ? `${selectedHere.length} ausgewählt` : `${subs.length} Produktgruppen`}</small></summary>
        ${body}
      </details>`;
    }).join("");
    // Bereits zugeordnete, hier nicht geführte Kategorien (z. B. Wiki/Technik
    // oder Altbestände) gehen nicht verloren und bleiben entfernbar.
    const others = [...selected].filter((category) => category !== "Archiv" && !shown.has(category));
    const othersBlock = others.length
      ? `<details class="product-category-accordion" open>
          <summary><span>Weitere zugeordnete Kategorien</span><small>${others.length} ausgewählt</small></summary>
          ${productCategorySubCheckboxes(others, selected, disabled)}
        </details>`
      : "";
    return `${sections}${othersBlock}`;
  }

  function categoryCheckboxes(selectedCategories, disabled, attributeName) {
    const selected = new Set(selectedCategories || []);
    const attr = attributeName || "data-product-category";
    const items = configuredCategories().filter((category) => category !== "Archiv");
    if (!items.length) return `<p class="editor-notice">Lege zuerst Kategorien an.</p>`;
    return `<div class="check-grid">${items.map((category) => `
      <label class="check-option">
        <input type="checkbox" value="${escapeHtml(category)}" ${attr}${selected.has(category) ? " checked" : ""}${disabled}>
        <span>${escapeHtml(category)}</span>
      </label>
    `).join("")}</div>`;
  }

  function productCheckboxes(selectedIds) {
    const selected = new Set(selectedIds || []);
    if (!products.length) {
      return `<p class="editor-notice">Lege zuerst ein Produkt im Menuepunkt Produkte an.</p>`;
    }
    return `<div class="check-grid">${products.map((product) => `
      <label class="check-option">
        <input type="checkbox" value="${escapeHtml(product.id)}" data-category-product${selected.has(product.id) ? " checked" : ""}>
        <span>${escapeHtml(productLabel(product.id))}</span>
      </label>
    `).join("")}</div>`;
  }

  function articleProductCheckboxes(selectedIds, disabled, categoryNames) {
    return articleProductDropdown(selectedIds, disabled, categoryNames);
  }

  function relatedArticleCheckboxes(currentSlug, selectedSlugs, disabled, categoryNames) {
    const selected = new Set(selectedSlugs || []);
    const items = relatedCandidates(currentSlug, categoryNames);
    if (!items.length) return `<div class="field-block"><span>Verwandte Artikel</span><p class="editor-notice">Keine weiteren Artikel in dieser Kategorie vorhanden.</p></div>`;
    const titleBySlug = new Map(items.map((article) => [article.slug, article.title]));
    // Bereits gespeicherte, aber kategorie-fremde Zuordnungen weiter anzeigen (nicht unbemerkt verlieren).
    const extraSlugs = [...selected].filter((slug) => !items.some((article) => article.slug === slug) && bySlug.has(slug) && !bySlug.get(slug).archived && slug !== currentSlug);
    const extraItems = extraSlugs.map((slug) => bySlug.get(slug));
    const label = dropdownLabel([...selected].map((slug) => titleBySlug.get(slug) || (bySlug.get(slug) || {}).title || slug), "Verwandte auswaehlen");
    return `<div class="field-block"><span>Verwandte Artikel</span>
    <details class="multi-select" data-related-dropdown>
      <summary>${escapeHtml(label)}</summary>
      <div class="multi-select-menu">
        <input class="multi-select-search" type="search" autocomplete="off" placeholder="Verwandte suchen (Titel)"${disabled} data-multi-select-search>
        ${items.map((article) => `
          <label class="check-option" data-filterable-option data-search="${escapeHtml(article.title)}">
            <input type="checkbox" value="${escapeHtml(article.slug)}" data-related-article${selected.has(article.slug) ? " checked" : ""}${disabled}>
            <span>${escapeHtml(article.title)}</span>
          </label>
        `).join("")}
        ${extraItems.map((article) => `
          <label class="check-option" data-filterable-option data-search="${escapeHtml(article.title)}">
            <input type="checkbox" value="${escapeHtml(article.slug)}" data-related-article checked${disabled}>
            <span>${escapeHtml(article.title)} (andere Kategorie)</span>
          </label>
        `).join("")}
      </div>
    </details><small class="muted-text">Nur Artikel der gewaehlten Kategorie. Bereits verknuepfte aus anderen Kategorien bleiben sichtbar, bis sie entfernt werden.</small></div>`;
  }

  function markdownEditor(name, value, disabled) {
    return `<div class="markdown-editor" data-markdown-editor>
      <div class="editor-mode-tabs" role="tablist" aria-label="Editoransicht">
        <button class="is-active" type="button" data-editor-mode="visual" role="tab" aria-selected="true"${disabled}>Texteditor</button>
        <button type="button" data-editor-mode="markdown" role="tab" aria-selected="false"${disabled}>Markdown</button>
      </div>
      <div class="markdown-toolbar" aria-label="Markdown Werkzeuge">
        <button type="button" data-md-action="bold"${disabled} title="Fett">B</button>
        <button type="button" data-md-action="italic"${disabled} title="Kursiv">I</button>
        <button type="button" data-md-action="h1"${disabled} title="Ueberschrift 1">H1</button>
        <button type="button" data-md-action="h2"${disabled} title="Ueberschrift 2">H2</button>
        <button type="button" data-md-action="ul"${disabled} title="Liste">- Liste</button>
        <button type="button" data-md-action="ol"${disabled} title="Nummerierte Liste">1. Liste</button>
        <button type="button" data-md-action="link"${disabled} title="Link">Link</button>
        <button type="button" data-md-action="image"${disabled} title="Bild einfuegen">Bild</button>
        <button type="button" data-md-action="caption"${disabled} title="Bildbeschriftung">Abb.</button>
        <button type="button" data-md-action="table"${disabled} title="Tabelle">Tabelle</button>
        <button type="button" data-md-tablegrid="toggle"${disabled} title="Tabellengroesse waehlen">Raster</button>
        <button type="button" data-md-table="rowAddAbove"${disabled} title="Zeile oberhalb einfuegen">↑Zeile</button>
        <button type="button" data-md-table="rowAdd"${disabled} title="Tabellenzeile hinzufuegen">+Zeile</button>
        <button type="button" data-md-table="rowDel"${disabled} title="Tabellenzeile entfernen">−Zeile</button>
        <button type="button" data-md-table="colAddLeft"${disabled} title="Spalte links einfuegen">←Spalte</button>
        <button type="button" data-md-table="colAdd"${disabled} title="Tabellenspalte hinzufuegen">+Spalte</button>
        <button type="button" data-md-table="colDel"${disabled} title="Tabellenspalte entfernen">−Spalte</button>
        <button type="button" data-md-table="delete"${disabled} title="Tabelle loeschen">Tabelle ✕</button>
        <select data-md-fontsize${disabled} title="Schriftgroesse" aria-label="Schriftgroesse">
          <option value="">Groesse</option>
          <option value="0.875rem">Klein</option>
          <option value="1rem">Normal</option>
          <option value="1.25rem">Gross</option>
          <option value="1.5rem">Sehr gross</option>
        </select>
        <input type="color" value="#1a1a1a" data-md-color${disabled} title="Textfarbe" aria-label="Textfarbe">
        <button type="button" data-md-action="quote"${disabled} title="Zitat">Zitat</button>
        <button type="button" data-md-action="code"${disabled} title="Code">Code</button>
      </div>
      <div class="markdown-workspace" data-editor-workspace>
        <div class="visual-editor article-body" contenteditable="true" data-visual-input${disabled ? " contenteditable=\"false\"" : ""}></div>
        <textarea name="${name}" rows="12" placeholder="# Ueberschrift" data-markdown-input hidden${disabled}>${escapeHtml(value || "")}</textarea>
      </div>
      <input type="file" accept="image/*" data-image-picker hidden${disabled}>
    </div>`;
  }

  function attachmentList(attachments) {
    if (!attachments || !attachments.length) return `<p class="muted-text">Keine Anhaenge vorhanden.</p>`;
    return `<div class="attachment-list">${attachments.map((attachment) => `
      <label class="attachment-item">
        <input type="checkbox" name="existingAttachment" value="${escapeHtml(attachment.path)}|${escapeHtml(attachment.name || "")}" checked>
        <a href="${escapeHtml(attachment.path)}" target="_blank" rel="noreferrer">${escapeHtml(attachment.name || attachment.path)}</a>
      </label>
    `).join("")}</div>`;
  }

  function attachmentPicker(disabled, attachments) {
    return `<div class="attachment-box">
      <div class="field-block">
        <span>Dateianhaenge</span>
        ${attachmentList(attachments || [])}
      </div>
      <label>
        <span>Neue Dateien hinzufuegen</span>
        <input name="attachmentFiles" type="file" multiple${disabled}>
      </label>
    </div>`;
  }

  function inlineProductDialog() {
    return `<dialog class="product-dialog" id="inlineProductDialog">
      <form class="article-form" id="inlineProductForm">
        <div class="section-title-row"><h2>Neues Produkt</h2><button class="icon-button" type="button" data-close-inline-product aria-label="Dialog schliessen" title="Dialog schliessen">×</button></div>
        <div class="form-grid">
          <label><span>Name</span><input name="name" required></label>
          <label><span>Artikel</span><input name="article" required></label>
          <label><span>Hardwarerevision</span><input name="hardwareRevision"></label>
          <label class="field-wide"><span>Beschreibung</span><textarea name="description" rows="2"></textarea></label>
        </div>
        <div class="field-block"><span>Kategorien</span>${categoryCheckboxes([], "", "data-product-category")}</div>
        <div class="form-actions"><button class="primary-button" type="submit">Produkt anlegen und auswaehlen</button><button class="secondary-button" type="button" data-close-inline-product>Abbrechen</button></div>
      </form>
    </dialog>`;
  }

  function editorPanel() {
    const selectedCategory = state.category === "Alle" || state.category === "Archiv"
      ? configuredCategories().find((category) => category !== "Archiv") || "Wiki Anleitung"
      : state.category;
    const selectedCategories = [selectedCategory].filter(Boolean);
    const disabled = dis("articles.create");

    return `<section class="editor-panel" id="wikiEditor">
      <div class="section-title-row">
        <h2>Neuer KB-Artikel</h2>
        <small id="editorStatus">${can("articles.create") ? "Editor-Modus aktiv" : "Keine Berechtigung zum Anlegen"}</small>
      </div>
      ${state.editorAvailable ? "" : `<p class="editor-notice">Zum direkten Speichern im Wiki starte zuerst <code>tools\\editor-server.ps1</code> und oeffne <code>http://127.0.0.1:8765/</code>. <button class="text-button" type="button" data-refresh-editor>Editor erneut pruefen</button></p>`}

      <form class="article-form" id="articleForm">
        <div class="form-grid">
          <label>
            <span>Titel</span>
            <input name="title" type="text" required placeholder="Artikelname"${disabled}>
          </label>
          <label>
            <span>Kategorien</span>
            ${articleCategoryDropdown(selectedCategories, disabled)}
          </label>
          <input name="tags" type="hidden" value="">
          <input name="relatedBase" type="hidden" value="">

          <label>
            <span>Verantwortlich</span>
            <input name="owner" type="text" placeholder="Wiki-Verantwortlicher" value="${state.user ? escapeHtml(state.user.displayName || state.user.username || '') : ''}"${disabled}>
          </label>
        </div>
        <div class="field-block" data-article-products-field>
          <div class="field-heading"><span>Produkte fuer diesen Artikel</span><button class="secondary-button compact-button" type="button" data-open-inline-product${disabled}>Neues Produkt anlegen</button></div>
          ${articleProductCheckboxes(productIdsForCategories(selectedCategories), disabled, selectedCategories)}
        </div>
        <div class="editor-field">
          <span>Artikelinhalt</span>
          ${markdownEditor("body", "# Ueberschrift\n\n", disabled)}
        </div>
        ${attachmentPicker(disabled, [])}
        ${relatedArticleCheckboxes("", [], disabled, selectedCategories)}
        <div class="form-actions">
          <button class="primary-button" type="submit"${disabled}>Artikel anlegen</button>
          <button class="secondary-button" type="button" data-cancel-create>Abbrechen</button>
        </div>
      </form>
      ${inlineProductDialog()}
    </section>`;
  }

  function structurePanel() {
    const disabled = dis("categories.manage");
    return `<div class="structure-grid">
      <form class="editor-panel compact-panel" id="groupForm">
        <h3>Neue Ueberkategorie</h3>
        <label>
          <span>Name</span>
          <input name="name" type="text" required placeholder="z. B. Zutrittskontrolle"${disabled}>
        </label>
        <div class="field-block">
          <span>Produktgruppen</span>
          <div class="check-grid">
            ${manageableCategories().map((category) => `
              <label class="check-option">
                <input type="checkbox" name="categories" value="${escapeHtml(category)}"${disabled}>
                <span>${escapeHtml(category)}</span>
              </label>
            `).join("")}
          </div>
        </div>
        <div class="field-block">
          <span>Neue Produktgruppe direkt anlegen</span>
          <input name="newCategoryName" type="text" autocomplete="off" placeholder="Name der neuen Produktgruppe (optional)"${disabled}>
          <small class="muted-text">Wird sofort dieser Ueberkategorie zugeordnet. Produkte koennen danach ueber „Zuordnung verwalten" bzw. die Kategorie-Filter zugeordnet werden.</small>
        </div>
        <div class="form-actions">
          <button class="secondary-button" type="submit"${disabled}>Ueberkategorie anlegen</button>
        </div>
      </form>
    </div>`;
  }

  function subcategoryPanel() {
    const disabled = canAssignCategories() ? "" : " disabled";
    return `<div class="structure-grid">
      <form class="editor-panel compact-panel" id="subcategoryForm">
        <h3>Neue Produktgruppe</h3>
        <p class="muted-text">Wird zunächst ohne Zuordnung angelegt und erscheint danach unter „Zuordnung verwalten".</p>
        <label>
          <span>Name</span>
          <input name="subcategoryName" type="text" required placeholder="z. B. IP-Kameras"${disabled}>
        </label>
        <div class="form-actions">
          <button class="secondary-button" type="submit"${disabled}>Produktgruppe anlegen</button>
        </div>
      </form>
    </div>`;
  }

  function subcategoryList() {
    const allCategories = manageableCategories();
    if (!allCategories.length) return "";
    const grouped = new Set(managedCategoryGroups().flatMap((group) => group.categories || []));
    const canDelete = can("categories.manage");
    return `<div class="user-list">${allCategories.map((category) => {
      const usage = categoryUsage(category);
      const assigned = managedCategoryGroups()
        .filter((group) => group.name !== "Weitere Kategorien" && (group.categories || []).includes(category))
        .map((group) => group.name);
      return `<div class="user-row suggestion-row">
        <div class="suggestion-main">
          <div><strong>${escapeHtml(category)}</strong>
            <small>${assigned.length ? `zugeordnet: ${assigned.map(escapeHtml).join(", ")}` : "nicht zugeordnet"}</small>
          </div>
          <p class="muted-text">${usage.articles.length} Artikel · ${usage.products.length} Produkte zugeordnet</p>
        </div>
        <div class="suggestion-actions">
          ${canDelete ? `<button class="danger-button" type="button" data-delete-category="${escapeHtml(category)}">Löschen</button>` : ""}
        </div>
      </div>`;
    }).join("")}</div>`;
  }

  function managedCategoryGroups() {
    return (wiki.categoryGroups || [])
      .map((group) => ({
        name: String(group.name || "").trim(),
        categories: Array.isArray(group.categories) ? group.categories : []
      }))
      .filter((group) => group.name);
  }

  function groupManagementForms() {
    // „Weitere Kategorien" ist nur ein Anzeige-Bucket, keine echte Überkategorie:
    // keine Karte, keine Speicher-/Lösch-Aktionen dafür (sonst würde sie echt).
    const groups = managedCategoryGroups().filter((group) => group.name !== "Archiv" && group.name !== "Weitere Kategorien");
    const allCategories = manageableCategories();
    if (!groups.length) {
      return `<div class="empty-state">
        <h2>Keine Ueberkategorien</h2>
        <p>Lege zuerst eine Ueberkategorie an, danach kannst du Kategorien zuordnen.</p>
      </div>`;
    }

    const disabled = canAssignCategories() ? "" : " disabled";
    const canDeleteGroup = can("categories.manage");
    return `<div class="group-manage-grid">${groups.map((group) => {
      const selected = new Set(group.categories || []);
      return `<form class="editor-panel compact-panel group-manage-card" data-group-manage-form data-group="${escapeHtml(group.name)}">
        <div class="section-title-row">
          <h3>${escapeHtml(group.name)}</h3>
          <small>${selected.size} Produktgruppen</small>
        </div>
        <input type="hidden" name="name" value="${escapeHtml(group.name)}">
        <div class="field-block">
          <span>Kategorien hinzufuegen oder entfernen</span>
          <div class="check-grid">
            ${allCategories.map((category) => `
              <label class="check-option">
                <input type="checkbox" name="categories" value="${escapeHtml(category)}"${selected.has(category) ? " checked" : ""}${disabled}>
                <span>${escapeHtml(category)}</span>
              </label>
            `).join("")}
          </div>
        </div>
        <div class="form-actions">
          <button class="secondary-button" type="submit"${disabled}>Zuordnung speichern</button>
          ${canDeleteGroup ? `<button class="danger-button" type="button" data-delete-group="${escapeHtml(group.name)}">Überkategorie löschen</button>` : ""}
        </div>
      </form>`;
    }).join("")}</div>`;
  }

  function ungroupedCategoryList() {
    const grouped = new Set(managedCategoryGroups()
      .filter((group) => group.name !== "Weitere Kategorien")
      .flatMap((group) => group.categories || []));
    const ungrouped = manageableCategories().filter((category) => !grouped.has(category));
    if (!ungrouped.length) return "";
    return `<section class="section-band">
      <div class="section-title-row">
        <h2>Nicht zugeordnet</h2>
        <small>${ungrouped.length} Kategorien</small>
      </div>
      <div class="tag-list category-tag-list">
        ${ungrouped.map((category) => `<span>${escapeHtml(category)}</span>`).join("")}
      </div>
    </section>`;
  }

  function categoriesPage() {
    return `<div class="page-head">
      <div>
        <p class="eyebrow">Strukturverwaltung</p>
        <h1>Kategorien</h1>
      </div>
      <div class="summary-strip">
        <span><strong>${managedCategoryGroups().length}</strong> Ueberkategorien</span>
        <span><strong>${configuredCategories().filter((category) => category !== "Alle").length}</strong> Kategorien</span>
      </div>
    </div>

    <section class="section-band">
      <div class="section-title-row">
        <h2>Überkategorie anlegen</h2>
        <small id="editorStatus">${state.editorAvailable ? "Editor-Modus aktiv" : "Editor-Modus nicht gestartet"}</small>
      </div>
      ${state.editorAvailable ? "" : `<p class="editor-notice">Zum Speichern muss der Editor-Modus aktiv sein. <button class="text-button" type="button" data-refresh-editor>Editor erneut pruefen</button></p>`}
      ${can("categories.manage") ? structurePanel() : `<p class="muted-text">Nur Administratoren können Überkategorien anlegen.</p>`}
    </section>

    <section class="section-band">
      <div class="section-title-row">
        <h2>Produktgruppe anlegen</h2>
        <small>unabhängig, ohne Zuordnung</small>
      </div>
      ${subcategoryPanel()}
    </section>

    <section class="section-band">
      <div class="section-title-row">
        <h2>Zuordnung verwalten</h2>
        <small>Produktgruppen je Ueberkategorie</small>
      </div>
      ${groupManagementForms()}
    </section>

    <section class="section-band">
      <div class="section-title-row">
        <h2>Produktgruppen</h2>
        <small>${manageableCategories().length} Einträge</small>
      </div>
      ${subcategoryList()}
    </section>

    ${ungroupedCategoryList()}`;
  }

  function renderArchive() {
    const archived = archivedArticles();
    els.view.innerHTML = `
      <div class="page-head">
        <div>
          <p class="eyebrow">Systemkategorie</p>
          <h1>Archiv</h1>
        </div>
        <div class="summary-strip">
          <span><strong>${archived.length}</strong> Artikel</span>
          <span><strong>${archivedProducts.length}</strong> Produkte</span>
        </div>
      </div>

      <section class="section-band">
        <div class="section-title-row">
          <h2>Archiv &rarr; Artikel</h2>
          <small>${archived.length} Eintraege</small>
        </div>
        ${archived.length ? tocList(archived) : `<p class="muted-text">Keine archivierten Artikel.</p>`}
      </section>

      <section class="section-band" id="archiv-produkte">
        <div class="section-title-row">
          <h2>Archiv &rarr; Produkte</h2>
          <small>${archivedProducts.length} Eintraege</small>
        </div>
        ${archivedProducts.length ? `<div class="product-list">${archivedProducts.map((product) => productListItem(product, true)).join("")}</div>` : `<p class="muted-text">Keine archivierten Produkte.</p>`}
      </section>
    `;
  }

  function renderHome() {
    const items = filteredArticles();
    const title = state.category === "Alle" ? "Alle Artikel" : `Kategorie: ${state.category}`;
    const landing = state.landing && state.category === "Alle" && !state.query.trim() && !state.showCreate;
    document.body.classList.toggle("is-wiki-home", landing);

    if (landing) {
      els.view.innerHTML = `<section class="wiki-home">
        <img src="assets/wissensdatenbank-logo.png" alt="Wissensdatenbank - Gesammeltes Wissen des Technischen Supports">
        <form class="home-search" id="homeSearchForm" role="search">
          <label for="homeSearchInput">Artikel suchen</label>
          <div><input id="homeSearchInput" name="query" type="search" autocomplete="off" placeholder="Wissen durchsuchen"><button class="primary-button" type="submit">Suchen</button></div>
        </form>
        <div class="home-facts">
          <span><strong>${activeArticles().length}</strong> aktive Artikel</span>
          <span><strong>${products.length}</strong> Produkte</span>
          <span><strong>${configuredCategories().length}</strong> Kategorien</span>
        </div>
        ${can("articles.create") ? `<div class="home-actions"><button class="primary-button" type="button" data-new-article-landing>Neuen Artikel erstellen</button></div>` : ""}
      </section>`;
      return;
    }
    document.body.classList.remove("is-wiki-home");

    // Systemkategorie Archiv: eigene Ansicht mit getrennten Bereichen,
    // archivierte Inhalte erscheinen ausschließlich hier.
    if (state.category === "Archiv") {
      renderArchive();
      return;
    }

    els.view.innerHTML = `
      <div class="page-head">
        <div>
          <p class="eyebrow">Offline Wissensbasis</p>
          <h1>${escapeHtml(title)}</h1>
        </div>
        <div class="summary-strip">
          <span><strong>${activeArticles().length}</strong> aktive Artikel</span>
          <span><strong>${archivedArticles().length}</strong> Archiv</span>
          <span><strong>${configuredCategories().length}</strong> Kategorien</span>
        </div>
      </div>

      <section class="section-band">
        <div class="section-title-row">
          <h2>Inhaltsverzeichnis</h2>
          <div class="form-actions">
            <small>${items.length} Artikel</small>
            <button class="primary-button" type="button" data-new-article${can("articles.create") && state.category !== "Archiv" ? "" : " disabled"}>Neuer KB-Artikel</button>
          </div>
        </div>
        <div class="filter-row" role="search">
          <label>
            <span>Suche</span>
            <input id="homeFilterSearch" type="search" autocomplete="off" placeholder="Suchbegriff" value="${escapeHtml(state.query)}">
          </label>
          <label>
            <span>Kategorie</span>
            <select id="homeFilterCategory">${["Alle", ...configuredCategories().filter((c) => c !== "Archiv")].map((c) => `<option value="${escapeHtml(c)}"${state.category === c ? " selected" : ""}>${escapeHtml(c)}</option>`).join("")}</select>
          </label>
          <label>
            <span>Produktfilter</span>
            <select id="productFilterSelect">${productOptionsForCategory(state.category, state.productFilter)}</select>
          </label>
          <button class="secondary-button" type="button" id="filterResetButton">Filter zurücksetzen</button>
        </div>
        ${tocList(items)}
      </section>
    `;
  }

  function productsPage() {
    const productGroups = productGroupsForPage();
    const visibleProducts = products.filter((product) => state.productCategoryFilter === "Alle" || (product.categories || []).includes(state.productCategoryFilter));
    const editProduct = state.editProductId ? products.find((product) => product.id === state.editProductId) : null;
    const deleteProduct = state.deleteProductId ? products.find((product) => product.id === state.deleteProductId) : null;
    return `<div class="page-head">
      <div>
        <p class="eyebrow">Produktverwaltung</p>
        <h1>Produkte</h1>
      </div>
      <div class="summary-strip">
        <span><strong>${products.length}</strong> Produkte</span>
        <span><strong>${archivedProducts.length}</strong> Archiv</span>
        <span><strong>${configuredCategories().filter((category) => category !== "Archiv").length}</strong> Kategorien</span>
      </div>
    </div>

    <section class="section-band">
      <div class="section-title-row">
        <h2>Produktliste</h2>
        <div class="form-actions">
          <small>${visibleProducts.length} Eintraege</small>
          <button class="primary-button" type="button" data-new-product${can("products.create") ? "" : " disabled"}>Neues Produkt</button>
        </div>
      </div>
      <div class="filter-row">
        <label>
          <span>Produktgruppenfilter</span>
          <select id="productCategoryFilterSelect">${categoryFilterOptions(state.productCategoryFilter)}</select>
        </label>
      </div>
      ${productCategoryGroupList(productGroups)}
    </section>

    ${editProduct ? productEditPanel(editProduct) : ""}
    ${deleteProduct ? productDeletePanel(deleteProduct) : ""}

    ${state.showProductCreate ? `<section class="editor-panel" id="productEditor">
      <div class="section-title-row">
        <h2>Neues Produkt</h2>
        <small id="editorStatus">${state.editorAvailable ? "Editor-Modus aktiv" : "Editor-Modus nicht gestartet"}</small>
      </div>
      ${state.editorAvailable ? "" : `<p class="editor-notice">Zum Speichern muss der Editor-Modus aktiv sein. <button class="text-button" type="button" data-refresh-editor>Editor erneut pruefen</button></p>`}
      <form class="article-form" id="productForm">
        <div class="form-grid">
          <label>
            <span>Name</span>
            <input name="name" type="text" required placeholder="Produktname"${dis("products.create")}>
          </label>
          <label>
            <span>Artikel</span>
            <input name="article" type="text" required placeholder="Artikelnummer"${dis("products.create")}>
          </label>
          <label>
            <span>Hardwarerevision</span>
            <input name="hardwareRevision" type="text" placeholder="z. B. Rev. 2"${dis("products.create")}>
          </label>
          <label class="field-wide">
            <span>Beschreibung</span>
            <textarea name="description" rows="2" placeholder="Produktbeschreibung"${dis("products.create")}></textarea>
          </label>
        </div>
        <div class="field-block">
          <span>Kategorien fuer dieses Produkt</span>
          ${productCategoryAccordion([], dis("products.create"))}
        </div>
        <div class="form-actions">
          <button class="primary-button" type="submit"${dis("products.create")}>Produkt anlegen</button>
          <button class="secondary-button" type="button" data-cancel-product-create>Abbrechen</button>
        </div>
      </form>
    </section>` : ""}

    <section class="section-band">
      <div class="section-title-row">
        <h2>Produktarchiv</h2>
        <small>${archivedProducts.length} Eintraege</small>
      </div>
      <p class="muted-text">Archivierte Produkte erscheinen ausschließlich unter Archiv &rarr; Produkte.</p>
      <div class="form-actions">
        <button class="secondary-button" type="button" data-goto-archive>Zum Archiv</button>
      </div>
    </section>`;
  }

  function accountPage() {
    const name = state.user ? (state.user.displayName || state.user.username) : "";
    const login = state.user ? state.user.username : "";
    return `<div class="page-head"><div><p class="eyebrow">Benutzerkonto</p><h1>Mein Konto</h1></div><div class="summary-strip"><span><strong>${escapeHtml(login)}</strong> Login-Name</span><span><strong>${escapeHtml(state.user ? state.user.role : "")}</strong> Rolle</span></div></div>
      <section class="editor-panel"><h2>Anzeigename aendern</h2>
        <p class="muted-text">Der Login-Name bleibt unveraendert. Rolle und Berechtigungen sind davon nicht betroffen.</p>
        <form id="accountNameForm" class="article-form"><div class="form-grid">
          <label><span>Anzeigename</span><input name="displayName" type="text" required maxlength="80" value="${escapeHtml(name)}"></label>
        </div><button class="primary-button" type="submit">Namen speichern</button></form>
      </section>
      <section class="editor-panel"><h2>Passwort aendern</h2>
        <p class="muted-text">Mindestens 10 Zeichen. Wird ausschliesslich als sicherer Hash gespeichert.</p>
        <form id="accountPasswordForm" class="article-form"><div class="form-grid">
          <label><span>Aktuelles Passwort</span><input name="currentPassword" type="password" required minlength="10" autocomplete="current-password"></label>
          <label><span>Neues Passwort</span><input name="newPassword" type="password" required minlength="10" autocomplete="new-password"></label>
          <label><span>Neues Passwort wiederholen</span><input name="newPasswordRepeat" type="password" required minlength="10" autocomplete="new-password"></label>
        </div><button class="primary-button" type="submit">Passwort speichern</button></form>
      </section>`;
  }

  async function handleAccountNameSubmit(form) {
    const displayName = form.elements.displayName.value.trim();
    if (!displayName) { setStatus("Anzeigename fehlt."); return; }
    const data = await apiRequest("/api/account", { method: "PUT", body: JSON.stringify({ displayName }) });
    state.user = data;
    updateAccountUi();
    render();
    setStatus("Anzeigename gespeichert.");
  }

  async function handleAccountPasswordSubmit(form) {
    const currentPassword = form.elements.currentPassword.value;
    const newPassword = form.elements.newPassword.value;
    if (newPassword !== form.elements.newPasswordRepeat.value) throw new Error("Die neuen Passwoerter stimmen nicht ueberein.");
    await apiRequest("/api/account", { method: "PUT", body: JSON.stringify({ currentPassword, newPassword }) });
    form.reset();
    render();
    setStatus("Passwort gespeichert.");
  }

  function usersPage() {
    if (!can("users.manage")) return `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Nur Benutzer mit Benutzerverwaltung duerfen Konten verwalten.</p></div>`;
    const roleNames = state.roles.length ? state.roles : Object.keys(state.rolePermissions || {});
    const roleOptions = (selected) => roleNames.map((name) => `<option${name === selected ? " selected" : ""}>${escapeHtml(name)}</option>`).join("");
    return `<div class="page-head"><div><p class="eyebrow">Administration</p><h1>Benutzer</h1></div><div class="summary-strip"><span><strong>${state.users.length}</strong> Konten</span><span><strong>${roleNames.length}</strong> Rollen</span></div></div>
      ${state.usersLoading ? `<p class="editor-notice">Benutzer werden geladen...</p>` : ""}
      <section class="section-band"><div class="section-title-row"><h2>Konten verwalten</h2><small>Rollen und Status</small></div>
        <div class="user-list">${state.users.map((user) => `<form class="user-row user-card" data-user-form data-username="${escapeHtml(user.username)}">
          <div class="user-identity"><strong>${escapeHtml(user.username)}</strong><small>Login-Name (unveraenderlich)</small></div>
          <label class="user-display"><span>Anzeigename</span><input name="displayName" type="text" maxlength="80" value="${escapeHtml(user.displayName || "")}" aria-label="Anzeigename fuer ${escapeHtml(user.username)}"></label>
          <div class="user-role">
            <label><span>Rolle</span><select name="role" aria-label="Rolle fuer ${escapeHtml(user.username)}">${roleOptions(user.role)}</select></label>
            <label class="inline-check"><input name="active" type="checkbox"${user.active ? " checked" : ""}> Aktiv</label>
          </div>
          <label class="user-pass"><span>Passwort</span><input name="password" type="password" minlength="10" placeholder="Neues Passwort (optional)" autocomplete="new-password"></label>
          <div class="user-save"><button class="secondary-button" type="submit">Speichern</button></div>
        </form>`).join("")}</div>
      </section>
      <section class="editor-panel"><h2>Neues Konto</h2><form id="newUserForm" class="article-form"><div class="form-grid">
        <label><span>Benutzername</span><input name="username" required minlength="3"></label>
        <label><span>Passwort</span><input name="password" type="password" required minlength="10" autocomplete="new-password"></label>
        <label><span>Rolle</span><select name="role">${roleOptions("Read-Only")}</select></label>
      </div><button class="primary-button" type="submit">Konto anlegen</button></form></section>
      ${canManageRoles() ? rolesSection() : ""}
      ${deleteRequestSection()}
      ${systemWarnings()}`;
  }

  function deleteRequestSection() {
    if (!can("articles.delete")) return "";
    const flagged = articles.filter((article) => !article.archived && article.deleteRequest && article.deleteRequest.by);
    const flaggedProducts = can("products.delete") ? products.filter((product) => product.deleteRequest && product.deleteRequest.by) : [];
    if (!flagged.length && !flaggedProducts.length) return `<section class="section-band"><div class="section-title-row"><h2>Loeschanfragen</h2><small>Keine offenen Anfragen</small></div>
      <p class="muted-text">Bearbeiter koennen Artikel und Produkte zum Loeschen vorschlagen. Aktuell liegt nichts zur Pruefung vor. Alle Anfragen mit Typ-Kennzeichnung stehen auch unter „Vorschlaege".</p></section>`;
    return `<section class="section-band"><div class="section-title-row"><h2>Loeschanfragen</h2><small>${flagged.length + flaggedProducts.length} zur Pruefung</small></div>
      <div class="user-list">${flagged.map((article) => `<div class="user-row suggestion-row">
        <div class="suggestion-main">
          <div><strong><span class="type-badge">Loeschung · Artikel</span> <a href="#/artikel/${escapeHtml(article.slug)}">${escapeHtml(article.title)}</a></strong><small>Vorgeschlagen von ${escapeHtml(article.deleteRequest.by)} am ${escapeHtml((article.deleteRequest.at || "").slice(0, 16).replace("T", " "))} – Grund: ${escapeHtml(article.deleteRequest.reason || "")}</small></div>
          ${rejectOpenFor("article-del", article.slug) ? rejectForm({ kind: "article-del", id: article.slug }) : ""}
        </div>
        <div class="suggestion-actions">
          <button class="secondary-button" type="button" data-goto-article="${escapeHtml(article.slug)}">Pruefen</button>
          <button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(article.slug)}" data-del-kind="article-del">Ablehnen</button>
        </div>
      </div>`).join("")}${flaggedProducts.map((product) => `<div class="user-row suggestion-row">
        <div class="suggestion-main">
          <div><strong><span class="type-badge">Loeschung · Produkt</span> ${escapeHtml(product.name)} <small>(${escapeHtml(product.article || "")})</small></strong><small>Vorgeschlagen von ${escapeHtml(product.deleteRequest.by)} am ${escapeHtml(String(product.deleteRequest.at || "").slice(0, 16).replace("T", " "))} – Grund: ${escapeHtml(product.deleteRequest.reason || "")}</small></div>
          ${rejectOpenFor("product-del", product.id) ? rejectForm({ kind: "product-del", id: product.id }) : ""}
        </div>
        <div class="suggestion-actions">
          <button class="secondary-button" type="button" data-goto-product="${escapeHtml(product.id)}">Pruefen</button>
          <button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(product.id)}" data-del-kind="product-del">Ablehnen</button>
        </div>
      </div>`).join("")}</div>
      <p class="muted-text">Zum endgueltigen Loeschen den Eintrag oeffnen und dort „Loeschen" verwenden. Abgelehnte Anfragen bleiben mit Begruendung sichtbar.</p></section>`;
  }

  function rolesSection() {
    const perms = state.allPermissions.length ? state.allPermissions : [];
    const roles = state.rolePermissions || {};
    return `<section class="section-band"><div class="section-title-row"><h2>Rollen und Rechte</h2><small>Berechtigungen je Rolle, spaeter erweiterbar</small></div>
      <form id="rolesForm" class="article-form">
        <div class="role-matrix">${Object.keys(roles).map((role) => `
          <fieldset class="role-card">
            <legend>${escapeHtml(role)}</legend>
            ${perms.map((perm) => `
              <label class="check-option">
                <input type="checkbox" name="perm:${escapeHtml(role)}" value="${escapeHtml(perm)}"${(roles[role] || []).includes(perm) ? " checked" : ""}>
                <span>${escapeHtml(permissionLabel(perm))}</span>
              </label>`).join("")}
          </fieldset>`).join("")}
        </div>
        <div class="form-actions">
          <button class="primary-button" type="submit">Rollen speichern</button>
        </div>
      </form>
      <form id="newRoleForm" class="article-form"><div class="form-grid">
        <label><span>Neue Rolle</span><input name="rolename" required minlength="3" maxlength="40" placeholder="z. B. Gastautor"></label>
      </div><button class="secondary-button" type="submit">Rolle anlegen</button></form>
    </section>`;
  }

  async function handleRolesSubmit(form) {
    if (!canManageRoles()) return;
    const roles = {};
    Object.keys(state.rolePermissions || {}).forEach((role) => { roles[role] = []; });
    form.querySelectorAll("input[type='checkbox']:checked").forEach((input) => {
      const role = input.name.startsWith("perm:") ? input.name.slice(5) : "";
      if (role && roles[role]) roles[role].push(input.value);
    });
    setStatus("Speichere Rollen...");
    const data = await apiRequest("/api/roles", { method: "PUT", body: JSON.stringify({ roles }) });
    state.roles = Object.keys(data.roles || {});
    state.rolePermissions = data.roles || {};
    state.allPermissions = Array.isArray(data.permissions) ? data.permissions : state.allPermissions;
    await detectEditor();
    render();
    setStatus("Rollen gespeichert.");
  }

  // Statusmodell: open = Warten auf Freigabe, accepted/rejected = Bearbeitet
  // (wartet auf Abschluss durch Ersteller). Legacy-Dateien ohne decision nutzen status.
  function suggestionState(item) {
    const status = (item && item.status) || "open";
    if (status === "accepted") return "accepted";
    if (status === "rejected") return "rejected";
    return "open";
  }

  function statusBadge(status) {
    if (status === "accepted") return `<span class="status-badge status-accepted">Bearbeitet · Genehmigt</span>`;
    if (status === "rejected") return `<span class="status-badge status-rejected">Bearbeitet · Abgelehnt</span>`;
    return `<span class="status-badge status-open">Warten auf Freigabe</span>`;
  }

  function decisionInfo(item) {
    // Genehmigt/Abgelehnt: Bearbeiter, Datum + (bei Ablehnung) Grund zeigen.
    if (!item) return "";
    const stateName = suggestionState(item);
    if (stateName === "open") return "";
    const when = String(item.processedAt || item.rejectedAt || "").slice(0, 16).replace("T", " ");
    const by = item.processedBy || item.rejectedBy || "";
    const reason = item.rejectionReason || "";
    if (stateName === "accepted") {
      return `<p class="decision-info decision-approved"><strong>Genehmigt</strong>${when || by ? `<small> (${[by ? "von " + by : "", when].filter(Boolean).join(" ")})</small>` : ""}</p>`;
    }
    return `<p class="rejection-info"><strong>Abgelehnt &rarr; ${escapeHtml(reason || "")}</strong>${when || by ? `<small> (${[by ? "von " + by : "", when].filter(Boolean).join(" ")})</small>` : ""}</p>`;
  }

  function rejectionInfo(item) {
    return decisionInfo(item);
  }

  function rejectForm(target) {
    return `<form class="reject-form" data-reject-form data-kind="${escapeHtml(target.kind)}" data-id="${escapeHtml(target.id)}">
      <label><span>Ablehnungsgrund (Pflichtfeld)</span><input name="reason" type="text" required maxlength="2000" placeholder="Warum wird der Vorschlag abgelehnt?"></label>
      <div class="form-actions">
        <button class="danger-button" type="submit">Ablehnung speichern</button>
        <button class="secondary-button" type="button" data-reject-cancel>Abbrechen</button>
      </div>
    </form>`;
  }

  function rejectOpenFor(kind, id) {
    return !!(state.rejectTarget && state.rejectTarget.kind === kind && state.rejectTarget.id === id);
  }

  function productFieldDiff(product, fields) {
    const labels = { name: "Name", article: "Artikel", hardwareRevision: "Hardwarerevision", description: "Beschreibung", categories: "Kategorien" };
    const rows = Object.keys(labels).filter((key) => fields && Object.prototype.hasOwnProperty.call(fields, key)).map((key) => {
      const oldValue = key === "categories" ? (product ? (product.categories || []).join(", ") : "") : (product ? String(product[key] || "") : "");
      const rawNew = fields[key];
      const newValue = key === "categories" ? (Array.isArray(rawNew) ? rawNew.join(", ") : String(rawNew || "")) : String(rawNew || "");
      if (oldValue === newValue) return "";
      return `<div><dt>${labels[key]}</dt><dd><span class="diff-old">${escapeHtml(oldValue) || "–"}</span> &rarr; <span class="diff-new">${escapeHtml(newValue) || "–"}</span></dd></div>`;
    }).join("");
    return rows ? `<dl class="field-diff">${rows}</dl>` : `<p class="muted-text">Keine Feldänderungen enthalten.</p>`;
  }

  function suggestionsPage() {
    if (!(can("articles.suggest") || can("articles.edit"))) return `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Vorschlaege sind nur mit Lese- oder Bearbeitungsrecht verfuegbar.</p></div>`;
    const reviewer = can("articles.edit");
    const items = state.suggestions || [];
    const openItems = items.filter((item) => suggestionState(item) === "open");
    const processedItems = items.filter((item) => suggestionState(item) !== "open");
    const myName = state.user ? state.user.username : "";
    const flaggedArticles = reviewer ? articles.filter((article) => !article.archived && article.deleteRequest && article.deleteRequest.by) : [];
    const flaggedProducts = reviewer && can("products.delete") ? products.filter((product) => product.deleteRequest && product.deleteRequest.by) : [];
    const deleteCount = flaggedArticles.length + flaggedProducts.length;
    const head = `<div class="page-head"><div><p class="eyebrow">Qualitaetssicherung</p><h1>Vorschlaege und Loeschanfragen</h1></div><div class="summary-strip"><span><strong>${openItems.length}</strong> warten auf Freigabe</span><span><strong>${deleteCount}</strong> Loeschanfragen</span><span><strong>${processedItems.length}</strong> bearbeitet</span></div></div>
      ${state.suggestionsLoading ? `<p class="editor-notice">Vorschlaege werden geladen...</p>` : ""}`;
    const renderSuggestionRow = (item) => {
      const isProduct = (item.kind || "article") === "product";
      const isDelete = (item.type || "change") === "delete";
      const product = isProduct ? productById.get(item.productId) || null : null;
      const article = !isProduct ? bySlug.get(item.slug) : null;
      const title = isDelete
        ? (item.title || item.slug || item.productId)
        : isProduct ? (item.title || (product ? product.name : item.productId)) : (article ? article.title : (item.title || item.slug));
      const link = !isProduct && !isDelete && item.slug ? `<a href="#/artikel/${escapeHtml(item.slug)}">${escapeHtml(title)}</a>` : escapeHtml(title);
      const preview = !isProduct && !isDelete ? String(item.body || "").slice(0, 400) : "";
      const stateName = suggestionState(item);
      const isOpen = stateName === "open";
      const isMine = myName && item.author === myName;
      const detail = isDelete
        ? (item.note ? `<p><strong>Begruendung des Vorschlags:</strong> ${escapeHtml(item.note)}</p>` : "")
        : !isProduct
          ? `<details><summary>Vorgeschlagene Aenderung anzeigen</summary><pre class="suggestion-preview">${escapeHtml(preview)}${String(item.body || "").length > 400 ? " …" : ""}</pre></details>`
          : `<details><summary>Vorgeschlagene Aenderung anzeigen</summary>${productFieldDiff(product, item.fields || {})}${item.note ? `<p><strong>Hinweis:</strong> ${escapeHtml(item.note)}</p>` : ""}</details>`;
      const typeLabel = isDelete ? (isProduct ? "Loeschung · Produkt" : "Loeschung · Artikel") : (isProduct ? "Aenderung · Produkt" : "Aenderung · Artikel");
      const canAct = reviewer && isOpen;
      return `<div class="user-row suggestion-row">
        <div class="suggestion-main">
          <div><strong><span class="type-badge">${typeLabel}</span> ${link}</strong> ${statusBadge(stateName)}<small>Vorgeschlagen von ${escapeHtml(item.authorDisplay || item.author)} am ${escapeHtml((item.createdAt || "").slice(0, 16).replace("T", " "))}${(!isProduct && !isDelete && item.note) ? ` – Hinweis: ${escapeHtml(item.note)}` : ""}</small></div>
          ${decisionInfo(item)}
          ${detail}
          ${rejectOpenFor("suggestion", item.id) ? rejectForm({ kind: "suggestion", id: item.id }) : ""}
        </div>
        <div class="suggestion-actions">
          ${canAct && !isProduct && !isDelete ? `<button class="primary-button" type="button" data-accept-suggestion="${escapeHtml(item.id)}" data-slug="${escapeHtml(item.slug)}">Genehmigen &amp; uebernehmen</button>` : ""}
          ${canAct && isProduct && !isDelete ? `<button class="primary-button" type="button" data-accept-suggestion="${escapeHtml(item.id)}" data-product="${escapeHtml(item.productId || "")}">Genehmigen &amp; uebernehmen</button>` : ""}
          ${canAct ? `<button class="secondary-button" type="button" data-reject-suggestion="${escapeHtml(item.id)}">Ablehnen</button>` : ""}
          ${isOpen && !canAct ? `<span class="muted-text">wartet auf Pruefung</span>` : ""}
          ${!isOpen && isMine ? `<button class="primary-button" type="button" data-acknowledge-suggestion="${escapeHtml(item.id)}">Abschließen</button>` : ""}
          ${!isOpen && !isMine && reviewer ? `<button class="secondary-button" type="button" data-delete-suggestion="${escapeHtml(item.id)}">Eintrag entfernen</button>` : ""}
        </div>
      </div>`;
    };
    const changeSection = !openItems.length && !processedItems.length
      ? `<div class="empty-state"><h2>Keine Vorschlaege</h2><p>${reviewer ? "Sobald Benutzer Aenderungen vorschlagen, erscheinen sie hier zur Pruefung." : "Deine eingereichten Vorschlaege erscheinen hier, bis sie uebernommen oder abgelehnt werden."}</p></div>`
      : `${openItems.length ? `<section class="section-band"><div class="section-title-row"><h2>Warten auf Freigabe</h2><small>${openItems.length} zur Pruefung</small></div><div class="user-list">${openItems.map(renderSuggestionRow).join("")}</div></section>` : ""}
        ${processedItems.length ? `<section class="section-band"><div class="section-title-row"><h2>Bearbeitet</h2><small>${reviewer ? "warten auf Abschluss durch Ersteller" : "bitte prüfen und abschließen"}</small></div><div class="user-list">${processedItems.map(renderSuggestionRow).join("")}</div></section>` : ""}`;
    let deleteSection = "";
    if (reviewer && (can("articles.delete") || can("products.delete"))) {
      const rows = [
        ...flaggedArticles.map((article) => `<div class="user-row suggestion-row">
          <div class="suggestion-main">
            <div><strong><span class="type-badge">Loeschung · Artikel</span> <a href="#/artikel/${escapeHtml(article.slug)}">${escapeHtml(article.title)}</a></strong><small>Vorgeschlagen von ${escapeHtml(article.deleteRequest.by)} am ${escapeHtml(String(article.deleteRequest.at || "").slice(0, 16).replace("T", " "))} – Grund: ${escapeHtml(article.deleteRequest.reason || "")}</small></div>
            ${rejectOpenFor("article-del", article.slug) ? rejectForm({ kind: "article-del", id: article.slug }) : ""}
          </div>
          <div class="suggestion-actions">
            <button class="secondary-button" type="button" data-goto-article="${escapeHtml(article.slug)}">Pruefen</button>
            ${can("articles.delete") ? `<button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(article.slug)}" data-del-kind="article-del">Ablehnen</button>` : ""}
          </div>
        </div>`),
        ...flaggedProducts.map((product) => `<div class="user-row suggestion-row">
          <div class="suggestion-main">
            <div><strong><span class="type-badge">Loeschung · Produkt</span> ${escapeHtml(product.name)} <small>(${escapeHtml(product.article || "")})</small></strong><small>Vorgeschlagen von ${escapeHtml(product.deleteRequest.by)} am ${escapeHtml(String(product.deleteRequest.at || "").slice(0, 16).replace("T", " "))} – Grund: ${escapeHtml(product.deleteRequest.reason || "")}</small></div>
            ${rejectOpenFor("product-del", product.id) ? rejectForm({ kind: "product-del", id: product.id }) : ""}
          </div>
          <div class="suggestion-actions">
            <button class="secondary-button" type="button" data-goto-product="${escapeHtml(product.id)}">Pruefen</button>
            <button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(product.id)}" data-del-kind="product-del">Ablehnen</button>
          </div>
        </div>`)
      ];
      deleteSection = `<section class="section-band"><div class="section-title-row"><h2>Loeschanfragen</h2><small>${deleteCount} zur Pruefung</small></div>${rows.length ? `<div class="user-list">${rows.join("")}</div><p class="muted-text">Zum endgueltigen Loeschen den Eintrag oeffnen und dort „Loeschen" verwenden.</p>` : `<p class="muted-text">Aktuell liegt nichts zur Pruefung vor.</p>`}</section>`;
    }
    return `${head}${changeSection}${deleteSection}`;
  }

  function systemWarnings() {
    const status = wiki.systemStatus || {};
    const report = status.conflicts || {};
    const conflicts = report.conflicts || [];
    const duplicates = report.duplicateSlugs || [];
    if (!status.buildError && !conflicts.length && !duplicates.length) return "";
    return `<section class="section-band warning-band"><h2>Systemhinweise</h2>
      ${status.buildError ? `<p><strong>Build:</strong> ${escapeHtml(status.buildError)}</p>` : ""}
      ${conflicts.length ? `<p>${conflicts.length} Synchronisierungskonflikt(e) wurden sicher ausgelagert. Abweichende Dateien liegen unter <code>content/conflicts/review</code>.</p>` : ""}
      ${duplicates.length ? `<p>${duplicates.length} doppelter Slug muss geprueft werden.</p>` : ""}
    </section>`;
  }

  // P4: Listen-Endpunkte liefern bei genau einem Eintrag ein einzelnes Objekt
  // statt eines Arrays (PowerShell-Serialisierung) — hier normalisieren.
  function asArray(data) {
    if (Array.isArray(data)) return data;
    if (data === null || data === undefined) return [];
    return [data];
  }

  async function loadUsers() {
    state.users = asArray(await apiRequest("/api/users"));
  }

  async function loadSuggestions() {
    state.suggestions = asArray(await apiRequest("/api/suggestions"));
    updateAccountUi();
  }

  async function loadRoles() {
    const data = await apiRequest("/api/roles");
    state.roles = Object.keys(data.roles || {});
    state.allPermissions = Array.isArray(data.permissions) ? data.permissions : [];
    state.rolePermissions = data.roles || {};
  }

  function permissionLabel(permission) {
    const labels = {
      "articles.view": "Artikel anzeigen", "articles.create": "Artikel erstellen",
      "articles.edit": "Artikel bearbeiten", "articles.delete": "Artikel loeschen",
      "articles.archive": "Artikel archivieren",
      "articles.suggest": "Aenderungen vorschlagen (Read-Only)",
      "articles.requestDelete": "Loeschung vorschlagen (Bearbeiter)",
      "products.view": "Produkte anzeigen",
      "products.create": "Produkte erstellen", "products.edit": "Produkte bearbeiten",
      "products.delete": "Produkte loeschen", "products.archive": "Produkte archivieren",
      "products.requestDelete": "Produktloeschung vorschlagen (Bearbeiter)",
      "categories.manage": "Kategorien verwalten (Überkategorien, Löschen)",
      "categories.assign": "Produktgruppen anlegen und zuordnen",
      "users.manage": "Benutzer verwalten",
      "roles.manage": "Rollen/Rechte verwalten"
    };
    return labels[permission] || permission;
  }

  async function acquireArticleLock(slug) {
    await apiRequest(`/api/locks/${encodeURIComponent(slug)}`, { method: "POST", body: "{}" });
    state.currentLockSlug = slug;
    clearInterval(state.lockTimer);
    state.lockTimer = setInterval(() => {
      if (state.currentLockSlug) apiRequest(`/api/locks/${encodeURIComponent(state.currentLockSlug)}`, { method: "POST", body: "{}" }).catch(() => releaseArticleLock());
    }, 60000);
  }

  async function releaseArticleLock() {
    const slug = state.currentLockSlug;
    state.currentLockSlug = "";
    clearInterval(state.lockTimer);
    state.lockTimer = null;
    if (slug) {
      try { await apiRequest(`/api/locks/${encodeURIComponent(slug)}`, { method: "DELETE", body: "{}" }); } catch (_) { /* Sperre laeuft serverseitig aus. */ }
    }
  }

  function productGroupsForPage() {
    const activeCategories = configuredCategories().filter((category) => category !== "Archiv");
    const selectedCategories = state.productCategoryFilter === "Alle"
      ? activeCategories
      : activeCategories.filter((category) => category === state.productCategoryFilter);

    const groups = selectedCategories.map((category) => ({
      name: category,
      products: products.filter((product) => (product.categories || []).includes(category))
    })).filter((group) => state.productCategoryFilter !== "Alle" || group.products.length);

    if (state.productCategoryFilter === "Alle") {
      const unassigned = products.filter((product) => !(product.categories || []).length);
      if (unassigned.length) groups.push({ name: "Nicht zugeordnet", products: unassigned });
    }

    return groups;
  }

  function productCategoryGroupList(groups) {
    if (!groups.length) {
      return `<div class="empty-state"><h2>Keine Produkte</h2><p>In dieser Auswahl ist kein aktives Produkt vorhanden.</p></div>`;
    }

    return `<div class="product-category-list">
      ${groups.map((group) => {
        const expanded = state.expandedProductCategories.has(group.name);
        return `<section class="product-category-group${expanded ? " is-open" : ""}">
          <button class="product-category-toggle" type="button" data-toggle-product-category="${escapeHtml(group.name)}" aria-expanded="${expanded}">
            <span>${escapeHtml(group.name)}</span>
            <small>${group.products.length} Produkte</small>
          </button>
          <div class="product-category-items">
            ${expanded ? `<div class="product-list">${group.products.map((product) => productListItem(product)).join("")}</div>` : ""}
          </div>
        </section>`;
      }).join("")}
    </div>`;
  }

  function productCategoryTags(product) {
    const items = product.categories || [];
    if (!items.length) return `<p class="muted-text">Keine Kategorien zugeordnet.</p>`;
    return `<div class="tag-list product-tags">${items.map((category) => `<span>${escapeHtml(category)}</span>`).join("")}</div>`;
  }

  function productCard(product, archived) {
    const successor = archived ? productById.get(product.id) : null;
    return `<article class="product-card${archived ? " is-archived" : ""}">
      <strong>${escapeHtml(product.name)}</strong>
      ${product.description ? `<p class="product-description">${escapeHtml(product.description)}</p>` : ""}
      <dl>
        <div><dt>Artikel</dt><dd>${escapeHtml(product.article)}</dd></div>
        <div><dt>Hardwarerevision</dt><dd>${escapeHtml(product.hardwareRevision || "Nicht gesetzt")}</dd></div>
        <div><dt>Revision</dt><dd>${escapeHtml(product.revision || 1)}</dd></div>
        <div><dt>Status</dt><dd>${escapeHtml(product.status || (archived ? "Archiviert" : "Aktiv"))}</dd></div>
        <div><dt>Letzte Aktion</dt><dd>${escapeHtml(product.changeAction || "Nicht gesetzt")}</dd></div>
        <div><dt>Grund</dt><dd>${escapeHtml(product.changeReason || "Nicht gesetzt")}</dd></div>
        ${archived ? `<div><dt>Archiviert am</dt><dd>${escapeHtml(formatDate((product.changeDate || "").slice(0, 10)))}</dd></div>` : ""}
      </dl>
      ${productCategoryTags(product)}
      ${archived && successor ? `<p><a class="text-link" href="#/produkte">Aktuelle Version ansehen (Rev. ${escapeHtml(successor.revision || 1)})</a></p>` : ""}
      ${archived ? "" : `<div class="form-actions product-actions">
        <button class="secondary-button" type="button" data-edit-product="${escapeHtml(product.id)}"${dis("products.edit")}>Bearbeiten</button>
        <button class="danger-button" type="button" data-delete-product="${escapeHtml(product.id)}"${dis("products.delete")}>Loeschen</button>
      </div>`}
    </article>`;
  }

  function productListItem(product, archived) {
    const successor = archived ? products.find((active) => active.id === product.id) || null : null;
    return `<article class="product-list-item${archived ? " is-archived" : ""}">
      <div class="product-list-main">
        <strong>${escapeHtml(product.name)}</strong>
        ${product.description ? `<p class="product-description">${escapeHtml(product.description)}</p>` : ""}
        <dl>
          <div><dt>Artikel</dt><dd>${escapeHtml(product.article)}</dd></div>
          <div><dt>Hardwarerevision</dt><dd>${escapeHtml(product.hardwareRevision || "Nicht gesetzt")}</dd></div>
          <div><dt>Revision</dt><dd>${escapeHtml(product.revision || 1)}</dd></div>
          <div><dt>Status</dt><dd>${escapeHtml(product.status || (archived ? "Archiviert" : "Aktiv"))}</dd></div>
        </dl>
        ${productCategoryTags(product)}
      </div>
      ${!archived ? renderProductDeleteRequestBanner(product) : ""}
      ${archived ? `<p class="muted-text">${escapeHtml(product.changeReason || "Archiviert")}${successor ? ` – <a class="text-link" href="#/produkte">aktuelle Version (Rev. ${escapeHtml(successor.revision || 1)})</a>` : ""}</p>
        ${can("products.delete") && !successor ? `<form class="inline-form" data-restore-product-form data-id="${escapeHtml(product.id)}">
          <input name="reason" type="text" required placeholder="Grund der Wiederherstellung" aria-label="Grund der Wiederherstellung">
          <button class="secondary-button" type="submit">Wiederherstellen</button>
        </form>` : ""}` : `<div class="form-actions product-actions">
        <button class="secondary-button" type="button" data-edit-product="${escapeHtml(product.id)}"${dis("products.edit")}>Bearbeiten</button>
        ${can("products.delete")
          ? `<button class="danger-button" type="button" data-delete-product="${escapeHtml(product.id)}">Loeschen</button>`
          : can("products.requestDelete") && !(product.deleteRequest && product.deleteRequest.by)
            ? `<form class="inline-form" data-request-delete-product-form data-id="${escapeHtml(product.id)}">
              <input name="reason" type="text" required placeholder="Grund des Loeschvorschlags" aria-label="Grund des Loeschvorschlags">
              <button class="danger-button" type="submit">Zum Loeschen vorschlagen</button>
            </form>` : ""}
      </div>`}
      ${!archived && can("articles.suggest") && can("products.view") && !can("products.edit") ? renderProductSuggestPanel(product) : ""}
    </article>`;
  }

  function renderProductSuggestPanel(product) {
    if (state.suggestProductId !== product.id) {
      return `<div class="form-actions product-actions"><button class="secondary-button" type="button" data-suggest-product="${escapeHtml(product.id)}">Aenderung vorschlagen</button></div>`;
    }
    return `<form class="article-form" data-suggest-product-form data-id="${escapeHtml(product.id)}">
      <div class="form-grid">
        <label><span>Name</span><input name="name" type="text" required value="${escapeHtml(product.name)}"></label>
        <label><span>Artikel</span><input name="article" type="text" required value="${escapeHtml(product.article)}"></label>
        <label><span>Hardwarerevision</span><input name="hardwareRevision" type="text" value="${escapeHtml(product.hardwareRevision || "")}"></label>
        <label class="field-wide"><span>Beschreibung</span><textarea name="description" rows="2">${escapeHtml(product.description || "")}</textarea></label>
      </div>
      <div class="field-block"><span>Kategorien fuer dieses Produkt</span>${categoryCheckboxes(product.categories || [], "", "data-suggest-product-category")}</div>
      <label><span>Hinweis an die Pruefer (optional)</span><input name="note" type="text" placeholder="Was soll geaendert werden und warum?"></label>
      <div class="form-actions">
        <button class="primary-button" type="submit">Vorschlag einreichen</button>
        <button class="secondary-button" type="button" data-suggest-product-cancel>Abbrechen</button>
      </div>
    </form>`;
  }
  function renderProductDeleteRequestBanner(product) {
    const request = product.deleteRequest;
    if (!request || !request.by) return "";
    const when = String(request.at || "").slice(0, 16).replace("T", " ");
    const actions = can("products.delete")
      ? `<div class="form-actions"><button class="danger-button" type="button" data-delete-product="${escapeHtml(product.id)}">Loeschen ausfuehren</button>
        <button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(product.id)}" data-del-kind="product-del">Ablehnen</button></div>
        ${rejectOpenFor("product-del", product.id) ? rejectForm({ kind: "product-del", id: product.id }) : ""}`
      : `<p class="muted-text">Die endgueltige Loeschung prueft ein Administrator.</p>`;
    return `<div class="editor-notice">
      <strong>Zur Loeschung vorgeschlagen</strong> von ${escapeHtml(request.by)}${when ? ` am ${escapeHtml(when)}` : ""}${request.reason ? ` – Grund: ${escapeHtml(request.reason)}` : ""}.
      ${actions}
    </div>`;
  }

  function productEditPanel(product) {
    return `<section class="editor-panel product-edit-panel">
      <div class="section-title-row">
        <h2>Produkt bearbeiten</h2>
        <small id="editorStatus">Revision ${escapeHtml(product.revision || 1)}</small>
      </div>
      <form class="article-form" id="editProductForm" data-product-id="${escapeHtml(product.id)}">
        <div class="form-grid">
          <label>
            <span>Name</span>
            <input name="name" type="text" required value="${escapeHtml(product.name)}">
          </label>
          <label>
            <span>Artikel</span>
            <input name="article" type="text" required value="${escapeHtml(product.article)}">
          </label>
          <label>
            <span>Hardwarerevision</span>
            <input name="hardwareRevision" type="text" value="${escapeHtml(product.hardwareRevision || "")}">
          </label>
          <label class="field-wide">
            <span>Beschreibung</span>
            <textarea name="description" rows="2" placeholder="Produktbeschreibung">${escapeHtml(product.description || "")}</textarea>
          </label>
        </div>
        <div class="field-block">
          <span>Kategorien fuer dieses Produkt</span>
          ${productCategoryAccordion(product.categories || [], "")}
        </div>
        <label>
          <span>Grund der Aenderung</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer Revision und Archiv">
        </label>
        <div class="form-actions">
          <button class="primary-button" type="submit">Aenderung speichern</button>
          <button class="secondary-button" type="button" data-cancel-product-edit>Abbrechen</button>
        </div>
      </form>
    </section>`;
  }

  function productDeletePanel(product) {
    return `<section class="editor-panel product-delete-panel">
      <div class="section-title-row">
        <h2>Produkt loeschen</h2>
        <small>Wird ins Produktarchiv verschoben</small>
      </div>
      <form class="article-form" id="deleteProductForm" data-product-id="${escapeHtml(product.id)}">
        <p class="archive-banner">${escapeHtml(productLabel(product.id))}</p>
        <label>
          <span>Grund der Loeschung</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer Archiv">
        </label>
        <div class="form-actions">
          <button class="danger-button" type="submit">Produkt loeschen und archivieren</button>
          <button class="secondary-button" type="button" data-cancel-product-delete>Abbrechen</button>
        </div>
      </form>
    </section>`;
  }

  function renderArticleEditor(article) {
    if (article.archived) return `<p class="editor-notice">Archivierte Artikel sind schreibgeschuetzt.</p>`;
    if (!can("articles.edit")) return `<p class="editor-notice">Bearbeiten und Loeschen ist nur mit entsprechender Berechtigung moeglich.</p>`;

    const selectedCategories = article.categories || [article.category].filter(Boolean);
    const prefill = state.suggestionPrefill && state.suggestionPrefill.slug === article.slug ? state.suggestionPrefill : null;
    const initialBody = prefill && typeof prefill.body === "string" ? prefill.body : (article.editBody || "");
    return `<section class="editor-panel article-edit-panel">
      <div class="section-title-row">
        <h2>Artikel bearbeiten</h2>
        <small id="editorStatus">Revision ${escapeHtml(article.revision || 1)}</small>
      </div>
      ${prefill ? `<p class="editor-notice">Aenderungsvorschlag von ${escapeHtml(prefill.authorDisplay || prefill.author || "")} wird uebernommen – nach dem Speichern wird der Vorschlag automatisch geschlossen.</p>` : ""}
      <form class="article-form" id="editArticleForm" data-slug="${escapeHtml(article.slug)}">
        <input type="hidden" name="baseRevision" value="${escapeHtml(article.revision || 1)}">
        <input type="hidden" name="relatedBase" value="${escapeHtml((article.related || []).join(","))}">
        <div class="form-grid">
          <label>
            <span>Titel</span>
            <input name="title" type="text" required value="${escapeHtml(article.title)}">
          </label>
          <label>
            <span>Kategorien</span>
            ${articleCategoryDropdown(selectedCategories, "")}
          </label>
          <label>
            <span>Tags</span>
            <input name="tags" type="text" value="${escapeHtml((article.tags || []).join(", "))}">
          </label>
          <label>
            <span>Verantwortlich</span>
            <input name="owner" type="text" value="${escapeHtml(article.owner || "")}">
          </label>
        </div>
        <div class="field-block" data-article-products-field>
          <div class="field-heading"><span>Produkte fuer diesen Artikel</span><button class="secondary-button compact-button" type="button" data-open-inline-product>Neues Produkt anlegen</button></div>
          ${articleProductCheckboxes(article.products || [], "", selectedCategories)}
          <small class="muted-text">Nur Produkte der gewaehlten Kategorie. Bei Kategoriewechsel unpassende Auswahl prüfen.</small>
        </div>
        <div class="editor-field">
          <span>Artikelinhalt</span>
          ${markdownEditor("body", initialBody, "")}
        </div>
        ${attachmentPicker("", article.attachments || [])}
        ${relatedArticleCheckboxes(article.slug, article.related || [], "", selectedCategories)}
        <label>
          <span>Grund der Aenderung</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer Revision und Archiv">
        </label>
        <div class="form-actions">
          <button class="primary-button" type="submit">Aenderung speichern</button>
          <button class="secondary-button" type="button" data-cancel-edit>Abbrechen</button>
        </div>
      </form>
      ${inlineProductDialog()}
    </section>`;
  }

  function renderDeletePanel(article) {
    if (article.archived || !can("articles.delete")) return "";
    return `<section class="editor-panel article-delete-panel">
      <div class="section-title-row">
        <h2>Artikel loeschen</h2>
        <small>Wird ins Archiv verschoben</small>
      </div>
      <form id="deleteArticleForm" data-slug="${escapeHtml(article.slug)}">
        <label>
          <span>Grund der Loeschung</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer Archiv">
        </label>
        <div class="form-actions">
          <button class="danger-button" type="submit">Artikel loeschen und archivieren</button>
          <button class="secondary-button" type="button" data-cancel-delete>Abbrechen</button>
        </div>
      </form>
    </section>`;
  }

  function renderRequestDeletePanel(article) {
    if (article.archived || !can("articles.requestDelete")) return "";
    return `<section class="editor-panel article-delete-panel">
      <div class="section-title-row">
        <h2>Loeschung vorschlagen</h2>
        <small>Wird einem Administrator zur Pruefung vorgelegt</small>
      </div>
      <form id="requestDeleteForm" data-slug="${escapeHtml(article.slug)}">
        <label>
          <span>Grund des Loeschvorschlags</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer die Pruefung">
        </label>
        <div class="form-actions">
          <button class="danger-button" type="submit">Zum Loeschen vorschlagen</button>
          <button class="secondary-button" type="button" data-cancel-delete>Abbrechen</button>
        </div>
      </form>
    </section>`;
  }

  function renderSuggestPanel(article) {
    if (article.archived || !can("articles.suggest")) return "";
    return `<section class="editor-panel article-edit-panel">
      <div class="section-title-row">
        <h2>Aenderung vorschlagen</h2>
        <small>Wird von Bearbeitern/Administratoren geprueft</small>
      </div>
      <form class="article-form" id="suggestArticleForm" data-slug="${escapeHtml(article.slug)}">
        <label>
          <span>Titel (Vorschlag)</span>
          <input name="title" type="text" value="${escapeHtml(article.title)}">
        </label>
        <div class="editor-field">
          <span>Vorgeschlagener Inhalt</span>
          <textarea name="body" rows="12" required>${escapeHtml(article.editBody || "")}</textarea>
        </div>
        <label>
          <span>Hinweis an die Pruefer (optional)</span>
          <input name="note" type="text" placeholder="Was soll geaendert werden und warum?">
        </label>
        <div class="form-actions">
          <button class="primary-button" type="submit">Vorschlag einreichen</button>
          <button class="secondary-button" type="button" data-cancel-suggest>Abbrechen</button>
        </div>
      </form>
    </section>`;
  }

  function renderDeleteRequestBanner(article) {
    const request = article.deleteRequest;
    if (article.archived || !request || !request.by) return "";
    const when = String(request.at || "").slice(0, 16).replace("T", " ");
    const actions = can("articles.delete")
      ? `<div class="form-actions"><button class="danger-button" type="button" data-delete-article="${escapeHtml(article.slug)}">Loeschen ausfuehren</button>
        <button class="secondary-button" type="button" data-reject-del-request="${escapeHtml(article.slug)}" data-del-kind="article-del">Ablehnen</button></div>
        ${rejectOpenFor("article-del", article.slug) ? rejectForm({ kind: "article-del", id: article.slug }) : ""}`
      : `<p class="muted-text">Die endgueltige Loeschung prueft ein Administrator.</p>`;
    return `<section class="editor-panel article-delete-panel">
      <div class="section-title-row"><h2>Zur Loeschung vorgeschlagen</h2><small>wartet auf Pruefung</small></div>
      <p>Vorgeschlagen von <strong>${escapeHtml(request.by)}</strong>${when ? ` am ${escapeHtml(when)}` : ""}${request.reason ? ` – Grund: ${escapeHtml(request.reason)}` : ""}.</p>
      ${actions}
    </section>`;
  }

  function renderRestorePanel(article) {
    if (!article.archived || !can("articles.delete")) return "";
    return `<section class="editor-panel article-restore-panel">
      <div class="section-title-row">
        <h2>Artikel wiederherstellen</h2>
        <small>Zurueck an die urspruengliche Position</small>
      </div>
      <form id="restoreArticleForm" data-slug="${escapeHtml(article.slug)}">
        <label>
          <span>Grund der Wiederherstellung</span>
          <input name="reason" type="text" required placeholder="Pflichtfeld fuer Revision">
        </label>
        <div class="form-actions">
          <button class="primary-button" type="submit">Wiederherstellen</button>
        </div>
      </form>
    </section>`;
  }

  // P9: eigenstaendige Editor-Seite (Erstellen + Bearbeiten).
  function editorPage(article) {
    const isNew = !article;
    if (isNew && !can("articles.create")) return `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Artikel erstellen ist nur mit entsprechender Berechtigung moeglich.</p></div>`;
    if (!isNew && !can("articles.edit")) return `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Artikel bearbeiten ist nur mit entsprechender Berechtigung moeglich.</p></div>`;
    if (!isNew && !article) return "";
    if (!isNew && state.currentLockSlug !== article.slug) {
      return `<div class="page-head"><div><p class="eyebrow">Artikel bearbeiten</p><h1>${escapeHtml(article.title)}</h1></div></div>
        <div class="empty-state"><h2>Bearbeitung starten?</h2><p>Der Artikel wird fuer 15 Minuten exklusiv fuer dich gesperrt.</p>
        <div class="form-actions"><button class="primary-button" type="button" data-edit-article="${escapeHtml(article.slug)}">Bearbeitung starten</button>
        <a class="secondary-button" href="#/artikel/${escapeHtml(article.slug)}">Zurueck zum Artikel</a></div></div>`;
    }
    return `<div class="page-head"><div><p class="eyebrow">${isNew ? "Neuer Artikel" : "Artikel bearbeiten"}</p><h1>${isNew ? "Artikel erstellen" : escapeHtml(article.title)}</h1></div></div>
      ${isNew ? editorPanel() : renderArticleEditor(article)}`;
  }

  function renderArticle(article, mode) {
    const related = (article.related || []).map((slug) => bySlug.get(slug)).filter(Boolean);
    const articleCategories = article.archived ? "Archiv" : (article.categories || [article.category]).filter(Boolean).join(", ");
    const showRequestDelete = !article.archived && !can("articles.delete") && can("articles.requestDelete") && !(article.deleteRequest && article.deleteRequest.by);
    const showSuggest = !article.archived && !can("articles.edit") && can("articles.suggest");
    els.view.innerHTML = `
      <article class="article-page">
        <div class="page-head article-head">
          <div>
            <p class="eyebrow">${escapeHtml(articleCategories || "Ohne Kategorie")}</p>
            <h1>${escapeHtml(article.title)}</h1>
            <p class="lead">${escapeHtml(article.summary || "")}</p>
          </div>
        </div>
        ${metaTable(article)}
        ${tagList(article.tags)}
        ${!article.archived ? `
          <div class="article-actions">
            <button class="secondary-button" type="button" data-edit-article="${escapeHtml(article.slug)}"${dis("articles.edit")}>Bearbeiten</button>
            ${can("articles.delete")
              ? `<button class="danger-button" type="button" data-delete-article="${escapeHtml(article.slug)}">Loeschen</button>`
              : showRequestDelete ? `<button class="danger-button" type="button" data-request-delete-article="${escapeHtml(article.slug)}">Zum Loeschen vorschlagen</button>` : ""}
            ${showSuggest ? `<button class="secondary-button" type="button" data-suggest-article="${escapeHtml(article.slug)}">Aenderung vorschlagen</button>` : ""}
          </div>
        ` : `<p class="archive-banner">Dieser Artikel ist archiviert.</p>
          ${can("articles.delete") && mode !== "restore" ? `<div class="article-actions"><button class="secondary-button" type="button" data-restore-article="${escapeHtml(article.slug)}">Wiederherstellen</button></div>` : ""}`}
        ${renderDeleteRequestBanner(article)}
        ${mode === "delete" ? renderDeletePanel(article) : ""}
        ${mode === "requestDelete" ? renderRequestDeletePanel(article) : ""}
        ${mode === "suggest" ? renderSuggestPanel(article) : ""}
        ${mode === "restore" ? renderRestorePanel(article) : ""}
        <div class="article-body">${article.html}</div>
        ${renderAttachments(article.attachments)}
        ${related.length ? `
          <section class="related-section">
            <h2>Verwandte Artikel</h2>
            <div class="related-list">
              ${related.map((item) => `<a href="${articleUrl(item)}">${escapeHtml(item.title)}</a>`).join("")}
            </div>
          </section>
        ` : ""}
      </article>
    `;
  }

  function renderMissing(slug) {
    els.view.innerHTML = `
      <div class="empty-state">
        <h1>Artikel nicht gefunden</h1>
        <p>Der Artikel "${escapeHtml(slug)}" ist in dieser Version nicht enthalten.</p>
        <a class="text-link" href="#/">Zur Startseite</a>
      </div>
    `;
  }

  function htmlToMarkdown(root) {
    const inline = (node) => {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent;
      if (node.nodeType !== Node.ELEMENT_NODE) return "";
      const tag = node.tagName.toLowerCase();
      const content = Array.from(node.childNodes).map(inline).join("");
      if (tag === "strong" || tag === "b") return `**${content}**`;
      if (tag === "em" || tag === "i") return `*${content}*`;
      if (tag === "s" || tag === "strike" || tag === "del") return `~~${content}~~`;
      if (tag === "code") return `\`${content}\``;
      if (tag === "span") {
        const clean = sanitizeSpanStyle(node.getAttribute("style") || "");
        return clean ? `<span style="${clean}">${content}</span>` : content;
      }
      if (tag === "a") return `[${content}](${node.getAttribute("href") || ""})`;
      if (tag === "img") {
        const src = node.getAttribute("src") || "";
        const alt = node.getAttribute("alt") || "Bild";
        const width = (node.style.width || node.getAttribute("width") || node.getAttribute("data-img-width") || "").replace("px", "");
        const figure = node.closest ? node.closest("figure") : null;
        const caption = figure ? (figure.querySelector("figcaption")?.textContent || "").trim() : "";
        return imageMarkdown(src, alt, width, caption);
      }
      if (tag === "figcaption") return "";
      if (tag === "br") return "\\\n";
      return content;
    };
    const block = (node) => {
      if (node.nodeType === Node.TEXT_NODE) return node.textContent.trim() ? `${node.textContent}\n\n` : "";
      if (node.nodeType !== Node.ELEMENT_NODE) return "";
      const tag = node.tagName.toLowerCase();
      if (/^h[1-6]$/.test(tag)) return `${"#".repeat(Number(tag[1]))} ${inline(node).trim()}\n\n`;
      if (tag === "figure") {
        const img = node.querySelector("img");
        if (img) return `${inline(img)}\n\n`;
        return "";
      }
      if (tag === "figcaption") return "";
      if (tag === "p" || tag === "div" || tag === "span") return `${normalizeBlockMarkers(inline(node).trim())}\n\n`;
      if (tag === "blockquote") return `${inline(node).split("\n").map((line) => `> ${line}`).join("\n")}\n\n`;
      if (tag === "ul" || tag === "ol") return `${Array.from(node.children).map((li, index) => `${tag === "ol" ? `${index + 1}.` : "-"} ${inline(li).trim()}`).join("\n")}\n\n`;
      if (tag === "pre") return `\`\`\`\n${node.textContent.replace(/\n$/, "")}\n\`\`\`\n\n`;
      if (tag === "table") {
        const cellText = (cell) => inline(cell).replace(/\\\n/g, " ").replace(/\n/g, " ").trim();
        const rows = Array.from(node.querySelectorAll("tr")).map((row) => Array.from(row.children).map((cell) => cellText(cell)));
        if (!rows.length) return "";
        return `| ${rows[0].join(" | ")} |\n| ${rows[0].map(() => "---").join(" | ")} |\n${rows.slice(1).map((row) => `| ${row.join(" | ")} |`).join("\n")}\n\n`;
      }
      if (tag === "img") return `${inline(node)}\n\n`;
      return Array.from(node.childNodes).map(block).join("");
    };
    return Array.from(root.childNodes).map(block).join("").replace(/\n{3,}/g, "\n\n").trimEnd();
  }

  function syncEditor(editor, source) {
    const markdown = editor.querySelector("[data-markdown-input]");
    const visual = editor.querySelector("[data-visual-input]");
    if (!markdown || !visual) return;
    if (source === "visual") markdown.value = htmlToMarkdown(visual);
    else visual.innerHTML = markdownToHtml(markdown.value);
  }

  function setEditorMode(editor, mode) {
    const markdown = editor.querySelector("[data-markdown-input]");
    const visual = editor.querySelector("[data-visual-input]");
    const nextMode = mode === "markdown" ? "markdown" : "visual";
    syncEditor(editor, nextMode === "markdown" ? "visual" : "markdown");
    markdown.hidden = nextMode !== "markdown";
    visual.hidden = nextMode !== "visual";
    editor.dataset.mode = nextMode;
    editor.querySelectorAll("[data-editor-mode]").forEach((button) => {
      const active = button.dataset.editorMode === nextMode;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-selected", String(active));
    });
  }

  function updateAllPreviews() {
    document.querySelectorAll("[data-markdown-editor]").forEach((editor) => {
      if (!editor.dataset.mode) setEditorMode(editor, "visual");
    });
  }

  function buildTableMarkdown(rows, cols) {
    rows = Math.min(Math.max(Number(rows) || 2, 1), 10);
    cols = Math.min(Math.max(Number(cols) || 2, 1), 8);
    const header = `| ${Array.from({ length: cols }, (_, i) => `Spalte ${i + 1}`).join(" | ")} |`;
    const sep = `| ${Array.from({ length: cols }, () => "---").join(" | ")} |`;
    const body = Array.from({ length: Math.max(rows - 1, 1) }, () => `| ${Array.from({ length: cols }, () => "Wert").join(" | ")} |`).join("\n");
    return `${header}\n${sep}\n${body}\n`;
  }

  function insertMarkdown(textarea, action, extra) {
    const start = textarea.selectionStart;
    const end = textarea.selectionEnd;
    const selected = textarea.value.slice(start, end);
    const samples = {
      bold: `**${selected || "fetter Text"}**`,
      italic: `*${selected || "kursiver Text"}*`,
      strike: `~~${selected || "durchgestrichener Text"}~~`,
      h1: `# ${selected || "Ueberschrift"}\n`,
      h2: `## ${selected || "Ueberschrift"}\n`,
      ul: `- ${selected || "Listenpunkt"}\n`,
      ol: `1. ${selected || "Listenpunkt"}\n`,
      link: `[${selected || "Linktext"}](https://)`,
      table: extra && extra.rows ? buildTableMarkdown(extra.rows, extra.cols) : "| Spalte 1 | Spalte 2 |\n| --- | --- |\n| Wert 1 | Wert 2 |\n",
      quote: `> ${selected || "Zitat"}\n`,
      code: selected.includes("\n") ? `\`\`\`\n${selected || "Code"}\n\`\`\`\n` : `\`${selected || "Code"}\``
    };
    const insert = samples[action] || selected;
    textarea.setRangeText(insert, start, end, "end");
    textarea.focus();
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // P6: markierten Visual-Text mit Schriftstil wrappen (span, reversibel via Markdown).
  function wrapVisualSelection(visual, property, value) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return false;
    const range = selection.getRangeAt(0);
    if (range.collapsed || !visual.contains(selection.anchorNode) || !visual.contains(selection.focusNode)) return false;
    const span = document.createElement("span");
    span.style[property] = value;
    try {
      span.appendChild(range.extractContents());
    } catch (_) { return false; }
    range.insertNode(span);
    selection.removeAllRanges();
    visual.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  }

  // P6: Tabelle an der Cursor-Position im Visual-Editor suchen.
  function visualTableAtCursor(visual) {
    const selection = window.getSelection();
    let node = selection && selection.rangeCount ? selection.anchorNode : null;
    if (node && node.nodeType === Node.TEXT_NODE) node = node.parentElement;
    const table = node && node.closest ? node.closest("table") : null;
    if (table && visual.contains(table)) return table;
    return visual.querySelector("table");
  }

  function visualTableCellCount(row) {
    return row ? row.children.length : 0;
  }

  function visualTableNewRow(table, referenceRow, header) {
    const count = Math.max(visualTableCellCount(referenceRow), visualTableCellCount(table.querySelector("tr")), 1);
    const row = document.createElement("tr");
    for (let i = 0; i < count; i += 1) {
      const cell = document.createElement(header ? "th" : "td");
      cell.appendChild(document.createElement("br"));
      row.appendChild(cell);
    }
    return row;
  }

  // P6: Tabellenstruktur im Visual-Editor aendern. Gibt meldungstaugliches Ergebnis zurueck.
  function visualTableEdit(visual, action) {
    const table = visualTableAtCursor(visual);
    if (action === "delete") {
      if (!table) return "Keine Tabelle gefunden.";
      table.remove();
      return "";
    }
    if (!table) return "Bitte zuerst den Cursor in eine Tabelle setzen.";
    const selection = window.getSelection();
    let cell = selection && selection.rangeCount ? selection.anchorNode : null;
    if (cell && cell.nodeType === Node.TEXT_NODE) cell = cell.parentElement;
    cell = cell && cell.closest ? cell.closest("th,td") : null;
    const row = cell && cell.parentElement ? cell.parentElement : table.querySelector("tr");
    if (!row) return "Keine Tabellenzeile gefunden.";
    const section = row.parentElement;
    const colIndex = cell ? Array.from(row.children).indexOf(cell) : row.children.length - 1;
    if (action === "rowAdd" || action === "rowAddAbove") {
      const fresh = visualTableNewRow(table, row, section.tagName === "THEAD");
      if (action === "rowAddAbove") section.insertBefore(fresh, row);
      else section.insertBefore(fresh, row.nextSibling);
    } else if (action === "rowDel") {
      if (table.querySelectorAll("tr").length <= 1) return "Die letzte Zeile kann nicht entfernt werden.";
      row.remove();
    } else if (action === "colAdd" || action === "colAddLeft" || action === "colDel") {
      const rows = Array.from(table.querySelectorAll("tr"));
      if (action === "colDel" && visualTableCellCount(rows[0]) <= 1) return "Die letzte Spalte kann nicht entfernt werden.";
      rows.forEach((current) => {
        if (action === "colDel") {
          const victim = current.children[Math.min(colIndex, current.children.length - 1)];
          if (victim) victim.remove();
        } else {
          const ref = current.children[Math.min(colIndex, current.children.length - 1)];
          const fresh = document.createElement(ref && ref.tagName === "TH" ? "th" : "td");
          fresh.appendChild(document.createElement("br"));
          if (action === "colAddLeft") {
            if (ref) current.insertBefore(fresh, ref);
            else current.appendChild(fresh);
          } else if (ref && ref.nextSibling) current.insertBefore(fresh, ref.nextSibling);
          else current.appendChild(fresh);
        }
      });
    }
    return "";
  }

  function insertVisualTable(visual, rows, cols) {
    rows = Math.min(Math.max(Number(rows) || 3, 1), 10);
    cols = Math.min(Math.max(Number(cols) || 3, 1), 8);
    const table = document.createElement("table");
    const thead = document.createElement("thead");
    const headRow = document.createElement("tr");
    for (let c = 0; c < cols; c += 1) {
      const th = document.createElement("th");
      th.textContent = `Spalte ${c + 1}`;
      headRow.appendChild(th);
    }
    thead.appendChild(headRow);
    table.appendChild(thead);
    const tbody = document.createElement("tbody");
    for (let r = 0; r < Math.max(rows - 1, 1); r += 1) {
      const tr = document.createElement("tr");
      for (let c = 0; c < cols; c += 1) {
        const td = document.createElement("td");
        td.textContent = "Wert";
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    const selection = window.getSelection();
    if (selection && selection.rangeCount && visual.contains(selection.anchorNode)) {
      const range = selection.getRangeAt(0);
      range.collapse(false);
      range.insertNode(table);
      range.setStartAfter(table);
      range.collapse(true);
      selection.removeAllRanges();
      selection.addRange(range);
    } else {
      visual.appendChild(table);
    }
    visual.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function valuesFromArticleForm(form) {
    const editor = form.querySelector("[data-markdown-editor]");
    if (editor) syncEditor(editor, editor.dataset.mode === "visual" ? "visual" : "markdown");
    const selectedCategories = Array.from(form.querySelectorAll("[data-article-category]:checked")).map((input) => input.value);
    const selectedRelated = Array.from(form.querySelectorAll("[data-related-article]:checked")).map((input) => input.value);
    const relatedBase = form.elements.relatedBase
      ? String(form.elements.relatedBase.value || "").split(",").map((slug) => slug.trim()).filter(Boolean)
      : [];
    const rawProducts = Array.from(form.querySelectorAll("[data-article-product]:checked")).map((input) => input.value);
    // Punkte 3/4: unpassende Produkte nicht unbemerkt speichern – herausfiltern, Hinweis geben.
    const invalid = validateCategoryProducts(selectedCategories, rawProducts);
    const currentSlug = form.dataset?.slug || "";
    const cleanRelated = selectedRelated.filter((slug) => slug !== currentSlug);
    return {
      title: form.elements.title.value,
      category: selectedCategories[0] || "",
      categories: selectedCategories,
      tags: (form.elements.tags ? form.elements.tags.value : "") || "",
      related: cleanRelated,
      relatedBase,
      owner: form.elements.owner.value,
      body: form.elements.body.value,
      products: rawProducts.filter((id) => !invalid.includes(id)),
      removedProducts: invalid,
      reason: form.elements.reason ? form.elements.reason.value : "",
      baseRevision: form.elements.baseRevision ? Number(form.elements.baseRevision.value) : undefined
    };
  }

  function productCategoriesFromForm(form) {
    return Array.from(form.querySelectorAll("[data-product-category]:checked")).map((input) => input.value);
  }

  function valuesFromProductForm(form) {
    return {
      name: form.elements.name.value,
      article: form.elements.article.value,
      hardwareRevision: form.elements.hardwareRevision.value,
      description: form.elements.description ? form.elements.description.value : "",
      categories: productCategoriesFromForm(form),
      reason: form.elements.reason ? form.elements.reason.value : ""
    };
  }

  async function handleCategorySubmit(form) {
    if (!can("categories.manage")) return;
    const name = form.elements.categoryName.value.trim();
    if (!name) return;
    await handleCategoryName(name);
  }

  async function handleCategoryName(name, root) {
    if (!can("categories.manage")) return;
    const scope = root || document;
    const productIds = Array.from(scope.querySelectorAll("[data-category-product]:checked")).map((input) => input.value);
    const groupInput = scope.querySelector("[data-category-group], [name='categoryGroup']");
    const group = groupInput ? groupInput.value : "";
    if (!productIds.length) {
      setStatus("Mindestens ein Produkt fuer die Kategorie auswaehlen");
      return;
    }
    setStatus("Speichere Kategorie...");
    const data = await apiRequest("/api/categories", { method: "POST", body: JSON.stringify({ name, products: productIds, group }) });
    state.category = name;
    await refreshFromServer(data);
    setStatus("Kategorie angelegt");
  }

  async function handleSubcategoryCreate(form) {
    if (!canAssignCategories()) return;
    const name = form.elements.subcategoryName ? form.elements.subcategoryName.value.trim() : "";
    if (!name) { setStatus("Name der Produktgruppe fehlt."); return; }
    if (manageableCategories().some((category) => category.toLowerCase() === name.toLowerCase())) {
      setStatus("Kategorie existiert bereits.");
      return;
    }
    setStatus("Speichere Produktgruppe...");
    const data = await apiRequest("/api/categories", { method: "POST", body: JSON.stringify({ name }) });
    await refreshFromServer(data);
    state.expandedGroups.add("Weitere Kategorien");
    render();
    setStatus(`Produktgruppe „${name}" angelegt – jetzt unter „Zuordnung verwalten" zuordnen.`);
  }

  async function handleDeleteCategoryGroup(name) {
    if (!can("categories.manage")) return;
    const group = managedCategoryGroups().find((item) => item.name === name);
    if (!group) return;
    const count = (group.categories || []).length;
    const hint = count
      ? `Dieser Überkategorie sind ${count} Produktgruppe(n) zugeordnet (${(group.categories || []).slice(0, 5).join(", ")}${count > 5 ? " …" : ""}). Die Produktgruppen werden nicht gelöscht, sondern nur von dieser Überkategorie getrennt. Wirklich löschen?`
      : `Überkategorie „${name}" wirklich löschen?`;
    if (!window.confirm(hint)) return;
    setStatus("Lösche Überkategorie...");
    const data = await apiRequest(`/api/category-groups/${encodeURIComponent(name)}`, { method: "DELETE", body: "{}" });
    await refreshFromServer(data);
    setStatus("Überkategorie gelöscht.");
  }

  async function handleDeleteCategory(name) {
    if (!can("categories.manage")) return;
    const usage = categoryUsage(name);
    if (usage.articles.length || usage.products.length) {
      const parts = [];
      if (usage.articles.length) parts.push(`${usage.articles.length} Artikel (${usage.articles.slice(0, 3).join(", ")})`);
      if (usage.products.length) parts.push(`${usage.products.length} Produkte (${usage.products.slice(0, 3).join(", ")})`);
      setStatus(`Löschen blockiert – Kategorie wird noch verwendet: ${parts.join("; ")}. Bitte zuerst die Zuordnungen entfernen.`);
      return;
    }
    if (!window.confirm(`Produktgruppe „${name}" wirklich vollständig löschen? Es wird kein Archiveintrag erzeugt.`)) return;
    setStatus("Lösche Produktgruppe...");
    const data = await apiRequest(`/api/categories/${encodeURIComponent(name)}`, { method: "DELETE", body: "{}" });
    await refreshFromServer(data);
    setStatus("Produktgruppe gelöscht.");
  }

  async function handleGroupCreate(form) {
    const name = form.elements.name ? form.elements.name.value.trim() : "";
    if (form.matches("[data-group-manage-form]") && !name) return;
    if (!name) return;
    // Neue Überkategorie -> nur Administrator; bestehende Zuordnung -> assign genügt.
    // „Weitere Kategorien" ist reserviert (Anzeigeordner) und wird nie angelegt.
    if (name === "Weitere Kategorien") { setStatus('Der Name "Weitere Kategorien" ist ein Anzeigeordner und keine Überkategorie.'); return; }
    const isNew = !managedCategoryGroups().some((group) => group.name === name);
    if (isNew && !can("categories.manage")) return;
    if (!isNew && !canAssignCategories()) return;
    const selected = Array.from(form.querySelectorAll("input[name='categories']:checked")).map((input) => input.value);
    const newCategoryInput = form.elements.newCategoryName;
    const newCategories = newCategoryInput && newCategoryInput.value.trim()
      ? [{ name: newCategoryInput.value.trim(), products: [] }]
      : [];
    setStatus("Speichere Ueberkategorie...");
    const data = await apiRequest("/api/category-groups", {
      method: "POST",
      body: JSON.stringify({ name, categories: selected, newCategories })
    });
    state.expandedGroups.add(name);
    await refreshFromServer(data);
    setStatus("Ueberkategorie gespeichert");
  }

  async function handleArticleCreate(form) {
    if (!can("articles.create") || state.saving) return;
    state.saving = true;
    const submitBtn = form.querySelector("button[type='submit']");
    if (submitBtn) { submitBtn.disabled = true; submitBtn.textContent = "Speichert..."; }
    setStatus("Speichere Artikel...");
    try {
      const values = valuesFromArticleForm(form);
      if (!values.title.trim()) { setStatus("Titel fehlt."); return; }
      if (values.removedProducts && values.removedProducts.length) {
        setStatus(`${values.removedProducts.length} Produkt(e) entfernt – passt nicht zur Kategorie.`);
      }
      values.attachmentFiles = await filesToPayload(form.elements.attachmentFiles?.files || []);
      setStatus("Lege Artikel an...");
      const data = await apiRequest("/api/articles", { method: "POST", body: JSON.stringify(values) });
      // Gespeicherten Artikel anhand der Server-Antwort ermitteln und direkt anspringen:
      // Hash zuerst setzen, dann neu laden – render() zeigt danach genau diesen Artikel.
      const savedSlug = data.savedSlug || slugify(values.title);
      const found = (data.articles || []).some((a) => a.slug === savedSlug);
      if (!found) throw new Error("Der gespeicherte Artikel wurde vom Server nicht bestaetigt.");
      state.showCreate = false;
      state.landing = false;
      state.category = "Alle";
      state.editorDirty = false;
      location.hash = `#/artikel/${savedSlug}`;
      await refreshFromServer(data);
      setStatus("Artikel gespeichert.");
    } catch (error) {
      setStatus(error.message || "Speichern fehlgeschlagen.");
      throw error;
    } finally {
      state.saving = false;
      const submitBtn = form.querySelector("button[type='submit']");
      if (submitBtn) { submitBtn.disabled = false; submitBtn.textContent = "Artikel anlegen"; }
    }
  }

  async function handleProductCreate(form) {
    if (!can("products.create")) return;
    setStatus("Speichere Produkt...");
    const data = await apiRequest("/api/products", {
      method: "POST",
      body: JSON.stringify(valuesFromProductForm(form))
    });
    state.showProductCreate = false;
    await refreshFromServer(data);
    location.hash = "#/produkte";
  }

  async function handleProductUpdate(form) {
    if (!can("products.edit")) return;
    const id = form.dataset.productId;
    const values = valuesFromProductForm(form);
    if (!values.reason.trim()) {
      setStatus("Grund der Aenderung fehlt");
      return;
    }
    setStatus("Speichere Produkt...");
    const data = await apiRequest(`/api/products/${encodeURIComponent(id)}`, {
      method: "PUT",
      body: JSON.stringify(values)
    });
    state.editProductId = "";
    await refreshFromServer(data);
    location.hash = "#/produkte";
  }

  async function handleProductDelete(form) {
    if (!can("products.delete")) return;
    const id = form.dataset.productId;
    const reason = form.elements.reason.value.trim();
    if (!reason) {
      setStatus("Grund der Loeschung fehlt");
      return;
    }
    if (!window.confirm("Produkt wirklich ins Archiv verschieben?")) return;
    setStatus("Verschiebe Produkt ins Archiv...");
    const data = await apiRequest(`/api/products/${encodeURIComponent(id)}`, {
      method: "DELETE",
      body: JSON.stringify({ reason })
    });
    state.deleteProductId = "";
    await refreshFromServer(data);
    location.hash = "#/produkte";
  }

  async function handleArticleUpdate(form) {
    if (!can("articles.edit")) return;
    const slug = form.dataset.slug;
    const values = valuesFromArticleForm(form);
    if (!values.reason.trim()) {
      setStatus("Grund der Aenderung fehlt");
      return;
    }
    values.attachments = selectedExistingAttachments(form);
    values.attachmentFiles = await filesToPayload(form.elements.attachmentFiles?.files || []);
    setStatus("Speichere Aenderung...");
    const data = await apiRequest(`/api/articles/${encodeURIComponent(slug)}`, { method: "PUT", body: JSON.stringify(values) });
    state.currentLockSlug = "";
    clearInterval(state.lockTimer);
    // Gespeicherten Artikel anhand der Server-Antwort ermitteln und direkt anspringen.
    const newSlug = data.savedSlug || slugify(values.title);
    const found = (data.articles || []).some((a) => a.slug === newSlug);
    if (!found) throw new Error("Der gespeicherte Artikel wurde vom Server nicht bestaetigt.");
    state.editorDirty = false;
    location.hash = `#/artikel/${newSlug}`;
    await refreshFromServer(data);
    if (state.consumeSuggestionId && state.consumeSuggestionSlug === newSlug) {
      try {
        await apiRequest(`/api/suggestions/${encodeURIComponent(state.consumeSuggestionId)}/accept`, { method: "POST", body: "{}" });
        await loadSuggestions().catch(() => {});
        setStatus("Aenderung gespeichert und Vorschlag uebernommen.");
      } catch (_) { setStatus("Aenderung gespeichert (Vorschlag konnte nicht automatisch geschlossen werden)."); }
      state.consumeSuggestionId = "";
      state.consumeSuggestionSlug = "";
      state.suggestionPrefill = null;
      return;
    }
    setStatus("Aenderung gespeichert.");
  }

  async function handleRequestDeleteSubmit(form) {
    if (!can("articles.requestDelete")) return;
    const slug = form.dataset.slug;
    const reason = form.elements.reason.value.trim();
    if (!reason) {
      setStatus("Grund des Loeschvorschlags fehlt");
      return;
    }
    setStatus("Reiche Loeschvorschlag ein...");
    const data = await apiRequest(`/api/articles/${encodeURIComponent(slug)}/request-delete`, { method: "POST", body: JSON.stringify({ reason }) });
    await refreshFromServer(data);
    setStatus("Loeschvorschlag eingereicht – ein Administrator prueft ihn.");
  }

  async function handleSuggestSubmit(form) {
    if (!can("articles.suggest")) return;
    const slug = form.dataset.slug;
    const title = form.elements.title.value.trim();
    const body = form.elements.body.value;
    const note = form.elements.note ? form.elements.note.value.trim() : "";
    if (!body.trim()) {
      setStatus("Der Vorschlag ist leer");
      return;
    }
    setStatus("Reiche Vorschlag ein...");
    await apiRequest("/api/suggestions", { method: "POST", body: JSON.stringify({ slug, title, body, note }) });
    await loadSuggestions().catch(() => {});
    const article = bySlug.get(slug);
    if (article) renderArticle(article);
    setStatus("Vorschlag eingereicht – danke!");
  }

  async function handleProductSuggestSubmit(form) {
    if (!can("articles.suggest")) return;
    const productId = form.dataset.id;
    const fields = {
      name: form.elements.name.value.trim(),
      article: form.elements.article.value.trim(),
      hardwareRevision: form.elements.hardwareRevision.value.trim(),
      description: form.elements.description.value,
      categories: Array.from(form.querySelectorAll("[data-suggest-product-category]:checked")).map((input) => input.value)
    };
    const note = form.elements.note ? form.elements.note.value.trim() : "";
    if (!fields.name || !fields.article) {
      setStatus("Name und Artikel sind Pflichtfelder");
      return;
    }
    setStatus("Reiche Vorschlag ein...");
    await apiRequest("/api/suggestions", { method: "POST", body: JSON.stringify({ kind: "product", productId, fields, note }) });
    state.suggestProductId = null;
    await loadSuggestions().catch(() => {});
    render();
    setStatus("Vorschlag eingereicht – danke!");
  }

  async function handleArticleRestoreSubmit(form) {
    if (!can("articles.delete")) return;
    const slug = form.dataset.slug;
    const reason = form.elements.reason.value.trim();
    if (!reason) {
      setStatus("Grund der Wiederherstellung fehlt");
      return;
    }
    setStatus("Stelle Artikel wieder her...");
    const data = await apiRequest(`/api/articles/${encodeURIComponent(slug)}/restore`, { method: "POST", body: JSON.stringify({ reason }) });
    const restoredSlug = data.savedSlug || "";
    if (restoredSlug) location.hash = `#/artikel/${restoredSlug}`;
    await refreshFromServer(data);
    setStatus("Artikel wiederhergestellt.");
  }

  async function handleArticleDelete(form) {    if (!can("articles.delete")) return;
    const slug = form.dataset.slug;
    const reason = form.elements.reason.value.trim();
    if (!reason) {
      setStatus("Grund der Loeschung fehlt");
      return;
    }
    if (!window.confirm("Artikel wirklich ins Archiv verschieben?")) return;
    setStatus("Verschiebe Artikel ins Archiv...");
    const data = await apiRequest(`/api/articles/${encodeURIComponent(slug)}`, { method: "DELETE", body: JSON.stringify({ reason }) });
    state.currentLockSlug = "";
    clearInterval(state.lockTimer);
    await refreshFromServer(data);
    state.category = "Archiv";
    location.hash = "#/";
  }

  function render() {
    if (!state.user) { renderAuth(); return; }
    document.body.classList.remove("is-wiki-home");
    renderNavigation();
    if (isUsersPage()) {
      els.view.innerHTML = usersPage();
      return;
    }
    if (isAccountPage()) {
      els.view.innerHTML = accountPage();
      return;
    }
    // P9: Editor-Routen vor der Artikel-Detailansicht behandeln (#/artikel/neu
    // und #/artikel/:slug/bearbeiten sind keine Artikel-Slugs).
    if (isNewArticlePage()) {
      els.view.innerHTML = editorPage(null);
      updateAllPreviews();
      return;
    }
    if (isEditArticlePage()) {
      const editSlug = getEditSlug();
      const editArticle = editSlug ? bySlug.get(editSlug) : null;
      if (!editArticle) {
        els.view.innerHTML = "";
        renderMissing(editSlug || "");
        return;
      }
      els.view.innerHTML = editorPage(editArticle);
      updateAllPreviews();
      return;
    }
    if (isSuggestionsPage()) {
      els.view.innerHTML = suggestionsPage();
      return;
    }
    if (isCategoriesPage()) {
      if (!(can("categories.manage") || can("articles.create") || can("articles.edit"))) {
        els.view.innerHTML = `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Die Strukturverwaltung ist nur mit entsprechender Berechtigung verfuegbar.</p></div>`;
        return;
      }
      els.view.innerHTML = categoriesPage();
      return;
    }
    if (isProductsPage()) {
      const productPerms = ["products.view", "products.create", "products.edit", "products.delete", "products.archive"];
      if (!productPerms.some((permission) => can(permission))) {
        els.view.innerHTML = `<div class="empty-state"><h1>Keine Berechtigung</h1><p>Die Produktverwaltung ist nur mit entsprechender Berechtigung verfuegbar.</p></div>`;
        return;
      }
      els.view.innerHTML = productsPage();
      return;
    }
    const slug = getCurrentSlug();
    if (!slug) renderHome();
    else {
      const article = bySlug.get(slug);
      if (article) renderArticle(article);
      else renderMissing(slug);
    }
    updateAllPreviews();
  }

  els.search.addEventListener("input", (event) => {
    state.query = event.target.value;
    state.landing = false;
    if (state.query.trim() && state.category !== "Archiv") state.category = "Alle";
    if (getCurrentSlug() || isProductsPage() || isCategoriesPage()) {
      if (location.hash === "#/") render();
      else location.hash = "#/";
      return;
    }
    render();
  });

  document.querySelector(".nav-home")?.addEventListener("click", (event) => {
    event.preventDefault();
    releaseArticleLock();
    state.category = "Alle";
    state.query = "";
    state.productFilter = "Alle";
    state.showCreate = false;
    state.landing = true;
    els.search.value = "";
    location.hash = "#/";
    render();
  });

  if (els.categoriesNav) {
    els.categoriesNav.addEventListener("click", () => {
      state.showCreate = false;
      state.landing = false;
      location.hash = "#/kategorien";
      render();
    });
  }

  if (els.productsNav) {
    els.productsNav.addEventListener("click", () => {
      state.showCreate = false;
      state.landing = false;
      state.expandedProductCategories = new Set();
      location.hash = "#/produkte";
      render();
    });
  }

  if (els.accountNav) {
    els.accountNav.addEventListener("click", async () => {
      if (!state.user) return;
      await releaseArticleLock();
      state.landing = false;
      location.hash = "#/konto";
      render();
    });
  }

  if (els.usersNav) {
    els.usersNav.addEventListener("click", async () => {
      if (!can("users.manage")) return;
      await releaseArticleLock();
      state.usersLoading = true;
      state.landing = false;
      location.hash = "#/benutzer";
      render();
      setStatus("Lade Benutzer...");
      try {
        await loadUsers();
        if (canManageRoles()) await loadRoles().catch(() => {});
      } catch (error) {
        setStatus(error.message || "Benutzer konnten nicht geladen werden.");
      } finally {
        state.usersLoading = false;
        if (isUsersPage()) render();
      }
    });
  }

  if (els.suggestionsNav) {
    els.suggestionsNav.addEventListener("click", async () => {
      if (!(can("articles.suggest") || can("articles.edit"))) return;
      await releaseArticleLock();
      state.suggestionsLoading = true;
      state.landing = false;
      location.hash = "#/vorschlaege";
      render();
      setStatus("Lade Vorschlaege...");
      try {
        await loadSuggestions().catch(() => {});
      } catch (error) {
        setStatus(error.message || "Vorschlaege konnten nicht geladen werden.");
      } finally {
        state.suggestionsLoading = false;
        if (isSuggestionsPage()) render();
      }
    });
  }

  if (els.logout) {
    els.logout.addEventListener("click", async () => {
      await releaseArticleLock();
      await apiRequest("/api/auth/logout", { method: "POST", body: "{}" });
      state.user = null;
      state.editorAvailable = false;
      updateAccountUi();
      renderAuth();
    });
  }

  if (els.theme) {
    els.theme.addEventListener("click", () => {
      state.theme = state.theme === "dark" ? "light" : "dark";
      try {
        localStorage.setItem("wiki-theme", state.theme);
      } catch (_) {
        // Darkmode bleibt fuer die aktuelle Sitzung aktiv, wenn localStorage nicht verfuegbar ist.
      }
      applyTheme();
    });
  }

  document.addEventListener("input", (event) => {
    if (event.target.matches("[data-markdown-input]")) syncEditor(event.target.closest("[data-markdown-editor]"), "markdown");
    // closest statt matches: Bildbeschriftungen (figcaption, eigener Editing-Host
    // innerhalb des visuellen Editors) feuern input mit der figcaption als Ziel.
    const visualHost = event.target.closest ? event.target.closest("[data-visual-input]") : null;
    if (visualHost) syncEditor(visualHost.closest("[data-markdown-editor]"), "visual");
    if (event.target.matches("[data-multi-select-search]")) filterMultiSelectOptions(event.target);
    // P9: Eingaben im Artikel-Editor als ungespeichert markieren.
    if (event.target.closest && event.target.closest("#articleForm, #editArticleForm")) state.editorDirty = true;
  });

  document.addEventListener("change", (event) => {
    // P9: auch Auswahl-Aenderungen (Checkboxen, Dropdowns, Uploads) sind ungespeichert.
    if (event.target.closest && event.target.closest("#articleForm, #editArticleForm")) state.editorDirty = true;
    const styleControl = event.target.closest ? event.target.closest("[data-md-fontsize], [data-md-color]") : null;
    if (styleControl) {
      const editor = styleControl.closest("[data-markdown-editor]");
      const visual = editor ? editor.querySelector("[data-visual-input]") : null;
      const textarea = editor ? editor.querySelector("[data-markdown-input]") : null;
      const isColor = styleControl.hasAttribute("data-md-color");
      const value = styleControl.value;
      if (!value) return;
      if (editor && editor.dataset.mode === "visual" && visual) {
        if (!wrapVisualSelection(visual, isColor ? "color" : "fontSize", value)) setStatus("Bitte zuerst Text markieren.");
        else syncEditor(editor, "visual");
      } else if (textarea) {
        const start = textarea.selectionStart;
        const end = textarea.selectionEnd;
        const selected = textarea.value.slice(start, end) || "Text";
        const style = isColor ? `color: ${value}` : `font-size: ${value}`;
        textarea.setRangeText(`<span style="${style}">${selected}</span>`, start, end, "end");
        textarea.focus();
        textarea.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (!isColor) styleControl.value = "";
      return;
    }
    if (event.target.id === "productFilterSelect") {
      state.productFilter = event.target.value;
      render();
    }
    if (event.target.id === "homeFilterCategory") {
      state.category = event.target.value;
      state.productFilter = "Alle";
      state.landing = false;
      render();
    }
    if (event.target.id === "homeFilterSearch") {
      state.query = event.target.value;
      if (els.search) els.search.value = event.target.value;
      state.landing = false;
      render();
    }
    if (event.target.id === "productCategoryFilterSelect") {
      state.productCategoryFilter = event.target.value;
      state.expandedProductCategories = new Set();
      render();
    }
    if (event.target.matches("#articleForm [data-article-category]")) {
      const form = event.target.closest("form");
      updateMultiSelectSummary(event.target.closest("[data-article-category-dropdown]"), "Kategorien auswaehlen");
      refreshCategoryDependentFields(form, "");
    }
    if (event.target.matches("#editArticleForm [data-article-category]")) {
      const form = event.target.closest("form");
      updateMultiSelectSummary(event.target.closest("[data-article-category-dropdown]"), "Kategorien auswaehlen");
      refreshCategoryDependentFields(form, form?.dataset.slug || "");
    }
    if (event.target.matches("[data-article-product]")) {
      updateMultiSelectSummary(event.target.closest("[data-article-product-dropdown]"), "Produkte auswaehlen", productLabel);
    }
    if (event.target.matches("[data-related-article]")) {
      updateMultiSelectSummary(event.target.closest("[data-related-dropdown]"), "Verwandte auswaehlen", (slug) => bySlug.get(slug)?.title || slug);
    }
    if (event.target.matches("[data-image-picker]")) {
      const editor = event.target.closest("[data-markdown-editor]");
      const file = event.target.files && event.target.files[0];
      uploadEditorImage(editor, file)
        .catch((error) => setStatus(error.message || "Bild konnte nicht eingefuegt werden."))
        .finally(() => { event.target.value = ""; });
    }
  });

  function syncImageToMarkdown(img, bounded) {
    // Schreibt Breite + Beschriftung in DOM und Markdown, OHNE den visuellen
    // Editor neu zu rendern: textarea-"input" wuerde syncEditor(markdown)
    // ausloesen und den img-Knoten mitten im Drag ersetzen (Resize-Abbruch,
    // Overlay-Verlust). Das visual-"input" schreibt nur markdown.value neu.
    const editor = img.closest ? img.closest("[data-markdown-editor]") : null;
    if (!editor) return;
    const src = img.getAttribute("src") || "";
    const alt = img.getAttribute("alt") || "Bild";
    const figure = img.closest ? img.closest("figure") : null;
    const caption = figure ? (figure.querySelector("figcaption")?.textContent || "").trim() : "";
    img.style.width = bounded + "px";
    img.style.maxWidth = "100%";
    img.setAttribute("data-img-width", bounded);
    const textarea = editor.querySelector("[data-markdown-input]");
    if (textarea) {
      const regex = new RegExp(`!\\[([^\\]]*)\\]\\(${escapeRegex(src)}\\)(?:\\{[^}]*\\})?`, "g");
      textarea.value = textarea.value.replace(regex, imageMarkdown(src, alt, bounded, caption));
    }
    const visual = editor.querySelector("[data-visual-input]");
    if (visual) visual.dispatchEvent(new Event("input", { bubbles: true }));
    state.editorDirty = true;
  }

  function clearImageOverlay() {
    document.querySelectorAll(".image-resize-overlay").forEach((el) => el.remove());
    document.querySelectorAll("img.editable-img.is-selected").forEach((el) => el.classList.remove("is-selected"));
  }

  function showImageOverlay(img) {
    clearImageOverlay();
    img.classList.add("is-selected");
    const overlay = document.createElement("div");
    overlay.className = "image-resize-overlay";
    const place = () => {
      const rect = img.getBoundingClientRect();
      if (!rect.width && !rect.height) return;
      overlay.style.left = `${rect.left + window.scrollX}px`;
      overlay.style.top = `${rect.top + window.scrollY}px`;
      overlay.style.width = `${rect.width}px`;
      overlay.style.height = `${rect.height}px`;
    };
    place();
    const handle = document.createElement("div");
    handle.className = "image-resize-handle";
    handle.title = "Ziehen zum Skalieren (Seitenverhältnis bleibt erhalten)";
    overlay.appendChild(handle);
    document.body.appendChild(overlay);
    const onScroll = () => {
      if (!document.body.contains(overlay)) { cleanup(); return; }
      if (!img.isConnected) { clearImageOverlay(); return; }
      place();
    };
    const cleanup = () => {
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", onScroll);
    };
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", onScroll);
    const startX = { x: 0, w: 0 };
    handle.addEventListener("mousedown", (downEvent) => {
      downEvent.preventDefault();
      downEvent.stopPropagation();
      startX.x = downEvent.clientX;
      startX.w = img.getBoundingClientRect().width || Number(img.getAttribute("data-img-width")) || 420;
      const onMove = (moveEvent) => {
        const next = Math.min(Math.max(Math.round(startX.w + (moveEvent.clientX - startX.x)), 80), 1200);
        syncImageToMarkdown(img, next);
        const fresh = img.getBoundingClientRect();
        overlay.style.width = `${fresh.width}px`;
        overlay.style.height = `${fresh.height}px`;
      };
      const onUp = () => {
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
      };
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
    });
    // Klick neben das Bild entfernt Overlay.
    setTimeout(() => {
      const dismiss = (e) => {
        if (e.target === handle || e.target === img) return;
        clearImageOverlay();
        cleanup();
        document.removeEventListener("mousedown", dismiss);
      };
      document.addEventListener("mousedown", dismiss);
    }, 0);
  }

  function editImageCaption(img) {
    const figure = img.closest ? img.closest("figure") : null;
    const current = figure ? (figure.querySelector("figcaption")?.textContent || "") : "";
    const next = window.prompt("Bildbeschriftung (z. B. Abb. 1: Aufbau)", current || "");
    if (next === null) return;
    const editor = img.closest ? img.closest("[data-markdown-editor]") : null;
    const visual = editor?.querySelector("[data-visual-input]");
    const caption = next.trim();
    if (figure) {
      let cap = figure.querySelector("figcaption");
      if (caption) {
        if (!cap) { cap = document.createElement("figcaption"); figure.appendChild(cap); }
        cap.textContent = caption;
        cap.contentEditable = "true";
      } else if (cap) cap.remove();
    } else if (caption && visual) {
      const wrap = document.createElement("figure");
      wrap.className = "wiki-figure";
      img.replaceWith(wrap);
      wrap.appendChild(img);
      const cap = document.createElement("figcaption");
      cap.textContent = caption;
      cap.contentEditable = "true";
      wrap.appendChild(cap);
    }
    const width = Number(img.getAttribute("data-img-width")) || 420;
    syncImageToMarkdown(img, width);
    setStatus(caption ? "Bildbeschriftung gespeichert." : "Bildbeschriftung entfernt.");
  }

  function toggleTableGrid(editor) {
    const existing = editor.querySelector(".table-grid-picker");
    if (existing) { existing.remove(); return; }
    const picker = document.createElement("div");
    picker.className = "table-grid-picker";
    picker.setAttribute("role", "grid");
    picker.title = "Tabellengröße wählen (Zeilen x Spalten)";
    for (let r = 1; r <= 5; r += 1) {
      for (let c = 1; c <= 5; c += 1) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.dataset.rows = String(r + 1);
        btn.dataset.cols = String(c + 1);
        btn.title = `${r + 1} x ${c + 1}`;
        btn.setAttribute("aria-label", `Tabelle ${r + 1} mal ${c + 1}`);
        btn.addEventListener("mouseenter", () => {
          picker.querySelectorAll("button").forEach((b) => {
            b.classList.toggle("is-picked", Number(b.dataset.rows) <= r + 1 && Number(b.dataset.cols) <= c + 1);
          });
        });
        btn.addEventListener("click", () => {
          const visual = editor.querySelector("[data-visual-input]");
          const textarea = editor.querySelector("[data-markdown-input]");
          if (editor.dataset.mode === "visual" && visual) {
            insertVisualTable(visual, r + 1, c + 1);
            syncEditor(editor, "visual");
          } else if (textarea) insertMarkdown(textarea, "table", { rows: r + 1, cols: c + 1 });
          picker.remove();
        });
        picker.appendChild(btn);
      }
    }
    editor.querySelector(".markdown-toolbar")?.appendChild(picker);
  }

  document.addEventListener("click", async (event) => {
    // Punkt 8: interaktive Skalierung über Ziehpunkte. Einfachklick = Overlay, Doppelklick = Breite/Beschriftung.
    const img = event.target.closest ? event.target.closest(".editable-img[data-img-resize]") : null;
    if (img && img.closest("[data-visual-input]")) {
      if (event.detail === 2) {
        const current = img.getAttribute("data-img-width") || "420";
        const answer = window.prompt("Bildbreite in Pixeln (80–1200) oder Beschriftung mit Präfix t: – z. B. t: Abb. 1: Aufbau", current);
        if (answer !== null && answer.trim() !== "") {
          if (/^t\s*:/i.test(answer)) editImageCaption(img);
          else syncImageToMarkdown(img, Math.min(Math.max(Number(answer) || 420, 80), 1200));
        }
      } else {
        showImageOverlay(img);
      }
      return;
    } else if (!event.target.closest || !event.target.closest(".image-resize-overlay")) {
      clearImageOverlay();
    }
    if (event.target.closest && event.target.closest("#filterResetButton")) {
      state.query = "";
      state.category = "Alle";
      state.productFilter = "Alle";
      state.landing = false;
      if (els.search) els.search.value = "";
      render();
      return;
    }
    if (event.target.closest && event.target.closest("#optionsCopyLink, #optionsPrint")) {
      const isCopy = Boolean(event.target.closest("#optionsCopyLink"));
      if (isCopy) {
        try {
          await navigator.clipboard.writeText(location.href);
          setStatus("Link kopiert.");
        } catch (_) { window.prompt("Link kopieren", location.href); }
      } else window.print();
      document.getElementById("optionsMenu")?.removeAttribute("open");
      return;
    }
    if (event.target.closest && event.target.closest("#optionsBackupCreate")) {
      document.getElementById("optionsMenu")?.removeAttribute("open");
      openBackupDialog("create");
      return;
    }
    if (event.target.closest && event.target.closest("#optionsBackupRestore")) {
      document.getElementById("optionsMenu")?.removeAttribute("open");
      openBackupDialog("restore");
      return;
    }

    const modeButton = event.target.closest("[data-editor-mode]");
    if (modeButton) {
      setEditorMode(modeButton.closest("[data-markdown-editor]"), modeButton.dataset.editorMode);
      return;
    }

    if (event.target.closest("[data-open-inline-product]")) {
      document.getElementById("inlineProductDialog")?.showModal();
      return;
    }

    if (event.target.closest("[data-close-inline-product]")) {
      document.getElementById("inlineProductDialog")?.close();
      return;
    }
    const groupToggle = event.target.closest("[data-toggle-group]");
    if (groupToggle) {
      const group = groupToggle.dataset.toggleGroup;
      if (state.expandedGroups.has(group)) state.expandedGroups.delete(group);
      else state.expandedGroups.add(group);
      render();
      return;
    }

    const productCategoryToggle = event.target.closest("[data-toggle-product-category]");
    if (productCategoryToggle) {
      const category = productCategoryToggle.dataset.toggleProductCategory;
      if (state.expandedProductCategories.has(category)) state.expandedProductCategories.delete(category);
      else state.expandedProductCategories.add(category);
      render();
      return;
    }

    const categoryButton = event.target.closest("[data-category]");
    if (categoryButton) {
      state.category = categoryButton.dataset.category;
      state.showCreate = false;
      state.landing = false;
      state.productFilter = "Alle";
      if (getCurrentSlug() || isProductsPage() || isCategoriesPage()) location.hash = "#/";
      render();
      return;
    }

    if (event.target.closest("[data-new-article-landing]")) {
      if (!can("articles.create") || state.category === "Archiv") return;
      await releaseArticleLock();
      state.showCreate = false;
      state.landing = false;
      state.category = "Alle";
      state.editorDirty = false;
      location.hash = "#/artikel/neu";
      render();
      return;
    }

    if (event.target.closest("[data-new-article]")) {
      if (!can("articles.create") || state.category === "Archiv") return;
      await releaseArticleLock();
      state.showCreate = false;
      state.editorDirty = false;
      location.hash = "#/artikel/neu";
      render();
      return;
    }

    if (event.target.closest("[data-new-product]")) {
      if (!can("products.create")) return;
      state.showProductCreate = true;
      state.editProductId = "";
      state.deleteProductId = "";
      render();
      document.getElementById("productEditor")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    if (event.target.closest("[data-cancel-product-create]")) {
      state.showProductCreate = false;
      render();
      return;
    }

    if (event.target.closest("[data-cancel-create]")) {
      state.showCreate = false;
      state.editorDirty = false;
      location.hash = "#/";
      render();
      return;
    }

    if (event.target.closest("[data-refresh-editor]")) {
      detectEditor();
      return;
    }

    if (event.target.closest("[data-create-category]")) {
      const input = document.querySelector("[data-category-name]");
      const name = input ? input.value.trim() : "";
      if (name) {
        handleCategoryName(name, event.target.closest(".category-inline")).catch((error) => setStatus(error.message || "Kategorie konnte nicht angelegt werden."));
      }
      return;
    }

    const toolbarButton = event.target.closest("[data-md-action]");
    if (toolbarButton) {
      const editor = toolbarButton.closest("[data-markdown-editor]");
      const textarea = editor ? editor.querySelector("[data-markdown-input]") : null;
      if (toolbarButton.dataset.mdAction === "image") {
        const picker = editor ? editor.querySelector("[data-image-picker]") : null;
        if (picker) picker.click();
        return;
      }
      if (toolbarButton.dataset.mdAction === "caption") {
        const visual = editor ? editor.querySelector("[data-visual-input]") : null;
        const img = visual ? (visual.querySelector("img.editable-img.is-selected") || visual.querySelector("img.editable-img")) : null;
        if (img) editImageCaption(img);
        else setStatus("Bitte zuerst ein Bild anklicken, dann Abb. wählen.");
        return;
      }
      if (toolbarButton.dataset.mdAction === "table") {
        const visual = editor ? editor.querySelector("[data-visual-input]") : null;
        if (editor?.dataset.mode === "visual" && visual) insertVisualTable(visual, 3, 3);
        else if (textarea) insertMarkdown(textarea, "table");
        if (editor && visual) syncEditor(editor, editor.dataset.mode === "visual" ? "visual" : "markdown");
        return;
      }
      const visual = editor ? editor.querySelector("[data-visual-input]") : null;
      if (editor?.dataset.mode === "visual" && visual) {
        const commands = { bold: "bold", italic: "italic", ul: "insertUnorderedList", ol: "insertOrderedList", quote: "formatBlock", h1: "formatBlock", h2: "formatBlock" };
        const action = toolbarButton.dataset.mdAction;
        if (commands[action]) document.execCommand(commands[action], false, action === "h1" ? "h1" : action === "h2" ? "h2" : action === "quote" ? "blockquote" : null);
        else { setEditorMode(editor, "markdown"); if (textarea) insertMarkdown(textarea, action); }
        syncEditor(editor, "visual");
      } else if (textarea) insertMarkdown(textarea, toolbarButton.dataset.mdAction);
      return;
    }

    const gridButton = event.target.closest("[data-md-tablegrid]");
    if (gridButton) {
      const editor = gridButton.closest("[data-markdown-editor]");
      if (editor) toggleTableGrid(editor);
      return;
    }

    const tableButton = event.target.closest("[data-md-table]");
    if (tableButton) {
      const editor = tableButton.closest("[data-markdown-editor]");
      const visual = editor ? editor.querySelector("[data-visual-input]") : null;
      if (!editor || !visual || editor.dataset.mode !== "visual") {
        setStatus("Zeilen und Spalten bitte in der Textansicht aendern – dort die Tabelle direkt bearbeiten.");
        return;
      }
      const message = visualTableEdit(visual, tableButton.dataset.mdTable);
      if (message) setStatus(message);
      else {
        syncEditor(editor, "visual");
        visual.dispatchEvent(new Event("input", { bubbles: true }));
        visual.focus();
      }
      return;
    }

    const editButton = event.target.closest("[data-edit-article]");
    if (editButton) {
      if (!can("articles.edit")) return;
      const article = bySlug.get(editButton.dataset.editArticle);
      if (article) {
        try {
          await acquireArticleLock(article.slug);
          state.editorDirty = false;
          location.hash = `#/artikel/${article.slug}/bearbeiten`;
          render();
          updateAllPreviews();
        } catch (error) { window.alert(error.message); }
      }
      return;
    }

    const deleteButton = event.target.closest("[data-delete-article]");
    if (deleteButton) {
      if (!can("articles.delete")) return;
      const article = bySlug.get(deleteButton.dataset.deleteArticle);
      if (article) {
        try { await acquireArticleLock(article.slug); renderArticle(article, "delete"); } catch (error) { window.alert(error.message); }
      }
      return;
    }

    const restoreButton = event.target.closest("[data-restore-article]");
    if (restoreButton) {
      if (!can("articles.delete")) return;
      const article = bySlug.get(restoreButton.dataset.restoreArticle);
      if (article) renderArticle(article, "restore");
      return;
    }

    const gotoArchiveButton = event.target.closest("[data-goto-archive]");
    if (gotoArchiveButton) {
      state.category = "Archiv";
      state.showCreate = false;
      state.landing = false;
      if (getCurrentSlug() || isProductsPage() || isCategoriesPage()) location.hash = "#/";
      render();
      return;
    }

    const gotoProductButton = event.target.closest("[data-goto-product]");
    if (gotoProductButton) {
      state.editProductId = "";
      state.deleteProductId = gotoProductButton.dataset.gotoProduct;
      state.productCategoryFilter = "Alle";
      location.hash = "#/produkte";
      render();
      document.querySelector(".product-delete-panel")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    const requestDeleteButton = event.target.closest("[data-request-delete-article]");
    if (requestDeleteButton) {
      if (!can("articles.requestDelete")) return;
      const article = bySlug.get(requestDeleteButton.dataset.requestDeleteArticle);
      if (article) renderArticle(article, "requestDelete");
      return;
    }

    const suggestButton = event.target.closest("[data-suggest-article]");
    if (suggestButton) {
      if (!can("articles.suggest")) return;
      const article = bySlug.get(suggestButton.dataset.suggestArticle);
      if (article) renderArticle(article, "suggest");
      return;
    }

    const suggestProductButton = event.target.closest("[data-suggest-product]");
    if (suggestProductButton) {
      if (!can("articles.suggest")) return;
      state.suggestProductId = suggestProductButton.dataset.suggestProduct;
      render();
      document.querySelector('[data-suggest-product-form]')?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    if (event.target.closest("[data-suggest-product-cancel]")) {
      state.suggestProductId = null;
      render();
      return;
    }

    const acceptButton = event.target.closest("[data-accept-suggestion]");
    if (acceptButton) {
      if (!can("articles.edit")) return;
      await runSaveAction(acceptButton, async () => {
        const item = (state.suggestions || []).find((entry) => entry.id === acceptButton.dataset.acceptSuggestion);
        if (!item) { setStatus("Vorschlag nicht gefunden."); return; }
        if ((item.kind || "article") === "product") {
          try {
            const data = await apiRequest(`/api/suggestions/${encodeURIComponent(item.id)}/accept`, { method: "POST", body: "{}" });
            await refreshFromServer(data);
            await loadSuggestions().catch(() => {});
            render();
            setStatus("Produktvorschlag uebernommen.");
          } catch (error) { setStatus(error.message || "Vorschlag konnte nicht uebernommen werden."); }
          return;
        }
        const article = bySlug.get(item.slug);
        if (!article) { setStatus("Vorschlag oder Artikel nicht gefunden."); return; }
        state.suggestionPrefill = { slug: item.slug, body: item.body, author: item.author, authorDisplay: item.authorDisplay };
        state.consumeSuggestionId = item.id;
        state.consumeSuggestionSlug = item.slug;
        state.editorDirty = false;
        try {
          await acquireArticleLock(article.slug);
          location.hash = `#/artikel/${article.slug}/bearbeiten`;
          render();
          updateAllPreviews();
        } catch (error) { window.alert(error.message); }
      });
      return;
    }

    const rejectButton = event.target.closest("[data-reject-suggestion]");
    if (rejectButton) {
      if (!can("articles.edit")) return;
      state.rejectTarget = { kind: "suggestion", id: rejectButton.dataset.rejectSuggestion };
      render();
      const input = document.querySelector('[data-reject-form] input[name="reason"]');
      if (input) input.focus();
      return;
    }

    const rejectDelButton = event.target.closest("[data-reject-del-request]");
    if (rejectDelButton) {
      const kind = rejectDelButton.dataset.delKind;
      if (kind === "article-del" && !can("articles.delete")) return;
      if (kind === "product-del" && !can("products.delete")) return;
      state.rejectTarget = { kind, id: rejectDelButton.dataset.rejectDelRequest };
      render();
      const input = document.querySelector('[data-reject-form] input[name="reason"]');
      if (input) input.focus();
      return;
    }

    const rejectCancelButton = event.target.closest("[data-reject-cancel]");
    if (rejectCancelButton) {
      state.rejectTarget = null;
      render();
      return;
    }

    const deleteSuggestionButton = event.target.closest("[data-delete-suggestion]");
    if (deleteSuggestionButton) {
      if (!can("articles.edit")) return;
      await runSaveAction(deleteSuggestionButton, async () => {
        try {
          await apiRequest(`/api/suggestions/${encodeURIComponent(deleteSuggestionButton.dataset.deleteSuggestion)}`, { method: "DELETE", body: "{}" });
          await loadSuggestions().catch(() => {});
          render();
          setStatus("Eintrag entfernt.");
        } catch (error) { setStatus(error.message || "Eintrag konnte nicht entfernt werden."); }
      });
      return;
    }

    const ackButton = event.target.closest("[data-acknowledge-suggestion]");
    if (ackButton) {
      if (!(can("articles.suggest") || can("articles.edit"))) return;
      await runSaveAction(ackButton, async () => {
        try {
          await apiRequest(`/api/suggestions/${encodeURIComponent(ackButton.dataset.acknowledgeSuggestion)}/acknowledge`, { method: "POST", body: "{}" });
          await loadSuggestions().catch(() => {});
          render();
          setStatus("Vorschlag abgeschlossen.");
        } catch (error) { setStatus(error.message || "Vorschlag konnte nicht abgeschlossen werden."); }
      });
      return;
    }

    const deleteGroupButton = event.target.closest("[data-delete-group]");
    if (deleteGroupButton) {
      if (!can("categories.manage")) return;
      await handleDeleteCategoryGroup(deleteGroupButton.dataset.deleteGroup).catch((error) => setStatus(error.message || "Überkategorie konnte nicht gelöscht werden."));
      return;
    }

    const deleteCategoryButton = event.target.closest("[data-delete-category]");
    if (deleteCategoryButton) {
      if (!can("categories.manage")) return;
      await handleDeleteCategory(deleteCategoryButton.dataset.deleteCategory).catch((error) => setStatus(error.message || "Kategorie konnte nicht gelöscht werden."));
      return;
    }

    const gotoButton = event.target.closest("[data-goto-article]");
    if (gotoButton) {
      location.hash = `#/artikel/${gotoButton.dataset.gotoArticle}`;
      render();
      return;
    }

    if (event.target.closest("[data-cancel-suggest]")) {
      const article = bySlug.get(getCurrentSlug());
      if (article) renderArticle(article);
      return;
    }

    const editProductButton = event.target.closest("[data-edit-product]");
    if (editProductButton) {
      if (!can("products.edit")) return;
      state.editProductId = editProductButton.dataset.editProduct;
      state.deleteProductId = "";
      render();
      document.querySelector(".product-edit-panel")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    const deleteProductButton = event.target.closest("[data-delete-product]");
    if (deleteProductButton) {
      if (!can("products.delete")) return;
      state.deleteProductId = deleteProductButton.dataset.deleteProduct;
      state.editProductId = "";
      render();
      document.querySelector(".product-delete-panel")?.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }

    if (event.target.closest("[data-cancel-product-edit]")) {
      state.editProductId = "";
      render();
      return;
    }

    if (event.target.closest("[data-cancel-product-delete]")) {
      state.deleteProductId = "";
      render();
      return;
    }

    if (event.target.closest("[data-cancel-edit]") || event.target.closest("[data-cancel-delete]")) {
      await releaseArticleLock();
      state.suggestionPrefill = null;
      state.consumeSuggestionId = "";
      state.consumeSuggestionSlug = "";
      state.editorDirty = false;
      // P9: Abbruch auf Editor-Route fuehrt zurueck (Detailseite bzw. Start).
      if (isEditArticlePage()) {
        const slug = getEditSlug();
        location.hash = slug ? `#/artikel/${slug}` : "#/";
        return;
      }
      if (isNewArticlePage()) {
        location.hash = "#/";
        return;
      }
      const article = bySlug.get(getCurrentSlug());
      if (article) renderArticle(article);
    }
  });

  document.addEventListener("submit", async (event) => {
    const busyButton = markSaveBusy(event);
    try {
      if (event.target.id === "setupForm" || event.target.id === "loginForm") {
        event.preventDefault();
        const form = event.target;
        if (form.id === "setupForm" && form.elements.password.value !== form.elements.passwordRepeat.value) throw new Error("Die Passwoerter stimmen nicht ueberein.");
        const path = form.id === "setupForm" ? "/api/auth/setup" : "/api/auth/login";
        const data = await apiRequest(path, { method: "POST", body: JSON.stringify({ username: form.elements.username.value, password: form.elements.password.value }) });
        state.user = data.user;
        state.setupRequired = false;
        await detectEditor();
      }
      if (event.target.id === "homeSearchForm") {
        event.preventDefault();
        state.query = event.target.elements.query.value;
        state.category = "Alle";
        state.landing = false;
        els.search.value = state.query;
        render();
      }
      if (event.target.id === "inlineProductForm") {
        event.preventDefault();
        const form = event.target;
        const before = new Set(products.map((product) => product.id));
        const data = await apiRequest("/api/products", { method: "POST", body: JSON.stringify(valuesFromProductForm(form)) });
        wiki = data;
        rebuildIndexes();
        const created = products.find((product) => !before.has(product.id));
        const articleForm = form.closest("dialog")?.closest("section")?.querySelector("#articleForm, #editArticleForm") || document.querySelector("#articleForm, #editArticleForm");
        const field = articleForm?.querySelector("[data-article-products-field]");
        const selected = Array.from(articleForm?.querySelectorAll("[data-article-product]:checked") || []).map((input) => input.value);
        if (created) selected.push(created.id);
        if (field) field.innerHTML = `<div class="field-heading"><span>Produkte fuer diesen Artikel</span><button class="secondary-button compact-button" type="button" data-open-inline-product>Neues Produkt anlegen</button></div>${articleProductCheckboxes([...new Set(selected)], "")}`;
        form.reset();
        document.getElementById("inlineProductDialog")?.close();
      }
      if (event.target.id === "accountNameForm") {
        event.preventDefault();
        await handleAccountNameSubmit(event.target);
      }
      if (event.target.id === "accountPasswordForm") {
        event.preventDefault();
        await handleAccountPasswordSubmit(event.target);
      }
      if (event.target.id === "newUserForm") {
        event.preventDefault();
        const form = event.target;
        state.users = asArray(await apiRequest("/api/users", { method: "POST", body: JSON.stringify({ username: form.elements.username.value, password: form.elements.password.value, role: form.elements.role.value }) }));
        render();
      }
      if (event.target.matches("[data-user-form]")) {
        event.preventDefault();
        const form = event.target;
        state.users = asArray(await apiRequest(`/api/users/${encodeURIComponent(form.dataset.username)}`, { method: "PUT", body: JSON.stringify({ role: form.elements.role.value, displayName: form.elements.displayName.value, active: form.elements.active.checked, password: form.elements.password.value }) }));
        await detectEditor();
        render();
      }
      if (event.target.id === "rolesForm") {
        event.preventDefault();
        await handleRolesSubmit(event.target);
      }
      if (event.target.id === "newRoleForm") {
        event.preventDefault();
        const name = event.target.elements.rolename.value.trim();
        if (name && !state.rolePermissions[name]) {
          state.rolePermissions[name] = [];
          render();
          setStatus(`Rolle „${name}" angelegt – jetzt Rechte setzen und speichern.`);
        }
      }
      if (event.target.id === "articleForm") {
        event.preventDefault();
        await handleArticleCreate(event.target);
      }
      if (event.target.id === "editArticleForm") {
        event.preventDefault();
        await handleArticleUpdate(event.target);
      }
      if (event.target.id === "deleteArticleForm") {
        event.preventDefault();
        await handleArticleDelete(event.target);
      }
      if (event.target.id === "restoreArticleForm") {
        event.preventDefault();
        await handleArticleRestoreSubmit(event.target);
      }
      if (event.target.id === "requestDeleteForm") {
        event.preventDefault();
        await handleRequestDeleteSubmit(event.target);
      }
      if (event.target.matches("[data-restore-product-form]")) {
        event.preventDefault();
        const form = event.target;
        if (!can("products.delete")) return;
        const reason = form.elements.reason.value.trim();
        if (!reason) { setStatus("Grund der Wiederherstellung fehlt."); return; }
        setStatus("Stelle Produkt wieder her...");
        const data = await apiRequest(`/api/products/${encodeURIComponent(form.dataset.id)}/restore`, { method: "POST", body: JSON.stringify({ reason }) });
        await refreshFromServer(data);
        setStatus("Produkt wiederhergestellt.");
      }
      if (event.target.matches("[data-request-delete-product-form]")) {
        event.preventDefault();
        const form = event.target;
        if (!can("products.requestDelete")) return;
        const reason = form.elements.reason.value.trim();
        if (!reason) { setStatus("Grund des Loeschvorschlags fehlt."); return; }
        setStatus("Reiche Loeschvorschlag ein...");
        const data = await apiRequest(`/api/products/${encodeURIComponent(form.dataset.id)}/request-delete`, { method: "POST", body: JSON.stringify({ reason }) });
        await refreshFromServer(data);
        setStatus("Loeschvorschlag eingereicht – ein Administrator prueft ihn.");
      }
      if (event.target.matches("[data-reject-form]")) {
        event.preventDefault();
        const form = event.target;
        const kind = form.dataset.kind;
        const id = form.dataset.id;
        const reason = form.elements.reason.value.trim();
        if (!reason) { setStatus("Bitte einen Ablehnungsgrund angeben."); return; }
        try {
          if (kind === "suggestion") {
            if (!can("articles.edit")) return;
            await apiRequest(`/api/suggestions/${encodeURIComponent(id)}/reject`, { method: "POST", body: JSON.stringify({ reason }) });
            await loadSuggestions().catch(() => {});
          } else if (kind === "article-del") {
            if (!can("articles.delete")) return;
            const data = await apiRequest(`/api/articles/${encodeURIComponent(id)}/request-delete`, { method: "DELETE", body: JSON.stringify({ reason }) });
            await refreshFromServer(data);
            await loadSuggestions().catch(() => {});
          } else if (kind === "product-del") {
            if (!can("products.delete")) return;
            const data = await apiRequest(`/api/products/${encodeURIComponent(id)}/request-delete`, { method: "DELETE", body: JSON.stringify({ reason }) });
            await refreshFromServer(data);
            await loadSuggestions().catch(() => {});
          } else {
            return;
          }
          state.rejectTarget = null;
          render();
          setStatus("Vorschlag abgelehnt.");
        } catch (error) { setStatus(error.message || "Vorschlag konnte nicht abgelehnt werden."); }
      }
      if (event.target.matches("[data-suggest-product-form]")) {
        event.preventDefault();
        await handleProductSuggestSubmit(event.target);
      }
      if (event.target.id === "suggestArticleForm") {
        event.preventDefault();
        await handleSuggestSubmit(event.target);
      }
      if (event.target.id === "productForm") {
        event.preventDefault();
        await handleProductCreate(event.target);
      }
      if (event.target.id === "editProductForm") {
        event.preventDefault();
        await handleProductUpdate(event.target);
      }
      if (event.target.id === "deleteProductForm") {
        event.preventDefault();
        await handleProductDelete(event.target);
      }
      if (event.target.id === "groupForm") {
        event.preventDefault();
        await handleGroupCreate(event.target);
      }
      if (event.target.id === "subcategoryForm") {
        event.preventDefault();
        await handleSubcategoryCreate(event.target);
      }
      if (event.target.matches("[data-group-manage-form]")) {
        event.preventDefault();
        await handleGroupCreate(event.target);
      }
    } catch (error) {
      if (!state.user) renderAuth(error.message || "Anmeldung fehlgeschlagen.");
      else setStatus(error.message || "Aktion fehlgeschlagen.");
    } finally {
      unmarkSaveBusy(busyButton);
    }
  });

  function backupDialogHtml(mode) {
    const isCreate = mode === "create";
    return `<dialog class="product-dialog" id="backupDialog" data-backup-mode="${isCreate ? "create" : "restore"}">
      <form class="article-form" id="backupForm" method="dialog">
        <div class="section-title-row"><h2>${isCreate ? "Backup erstellen" : "Backup wiederherstellen"}</h2><button class="icon-button" type="button" data-close-backup aria-label="Dialog schliessen">×</button></div>
        ${isCreate ? `<p class="muted-text">Sichert Artikel, Kategorien, Produkte, Zuordnungen, Inhalte, Bilder und Metadaten als versioniertes Backup (backupVersion 1). Ziel: Server-Sicht – lokale Pfade gelten am Server, WebDAV optional.</p>
        <div class="form-grid">
          <label><span>Zielpfad (optional, z. B. D:\\WikiBackup oder \\\\Server\\Backup\\Wiki)</span><input name="targetPath" type="text" placeholder="Leer = Download + Server-Ordner versions\\backups"></label>
          <label><span>WebDAV URL (optional)</span><input name="webdavUrl" type="text" placeholder="https://.../remote.php/dav/files/.../"></label>
          <label><span>WebDAV Benutzer</span><input name="webdavUser" type="text" autocomplete="off"></label>
          <label><span>WebDAV Passwort/Token</span><input name="webdavPassword" type="password" autocomplete="off"></label>
        </div>` : `<p class="muted-text"><strong>Achtung:</strong> Bestehende Daten können überschrieben werden. Backup wird vorab validiert (Format/Version). Möchten Sie dieses Backup wirklich wiederherstellen? Bestehende Daten können dadurch überschrieben werden.</p>
        <div class="form-grid">
          <label><span>Backup-Datei (.zip)</span><input name="backupFile" type="file" accept=".zip,application/zip" required></label>
          <label class="field-wide"><span>Sicherheitsbestätigung (bitte ÜBERSCHREIBEN eingeben)</span><input name="confirm" type="text" required placeholder="ÜBERSCHREIBEN"></label>
        </div>`}
        <div class="backup-progress" id="backupProgress" hidden><span class="spinner"></span><span id="backupProgressText">${isCreate ? "Backup wird erstellt ..." : "Wiederherstellung läuft ..."}</span></div>
        <p class="editor-notice" id="backupStatus"></p>
        <div class="form-actions">
          <button class="primary-button" type="submit" id="backupSubmit">${isCreate ? "Backup starten" : "Wiederherstellen"}</button>
          <button class="secondary-button" type="button" data-close-backup>Abbrechen</button>
        </div>
      </form>
    </dialog>`;
  }

  function openBackupDialog(mode) {
    if (!isAdmin()) { setStatus("Nur für Administratoren."); return; }
    if (state.backupBusy) { setStatus("Backup/Restore läuft bereits ..."); return; }
    document.getElementById("backupDialog")?.remove();
    document.body.insertAdjacentHTML("beforeend", backupDialogHtml(mode));
    document.getElementById("backupDialog")?.showModal();
  }

  async function handleBackupSubmit(form) {
    if (!isAdmin() || state.backupBusy) return;
    const mode = document.getElementById("backupDialog")?.dataset.backupMode || "create";
    const progress = document.getElementById("backupProgress");
    const statusEl = document.getElementById("backupStatus");
    const submit = document.getElementById("backupSubmit");
    state.backupBusy = true;
    if (progress) progress.hidden = false;
    if (submit) submit.disabled = true;
    const say = (msg) => { if (statusEl) statusEl.textContent = msg; setStatus(msg); };
    try {
      if (mode === "create") {
        say("Backup wird erstellt ...");
        const payload = {
          targetPath: form.elements.targetPath?.value || "",
          webdavUrl: form.elements.webdavUrl?.value || "",
          webdavUser: form.elements.webdavUser?.value || "",
          webdavPassword: form.elements.webdavPassword?.value || ""
        };
        const data = await apiRequest("/api/backup/create", { method: "POST", body: JSON.stringify(payload) });
        say(`Backup erfolgreich: ${data.fileName || "Backup"} (${data.articleCount || 0} Artikel, ${data.imageCount || 0} Bilder).`);
        if (data.downloadUrl) {
          const a = document.createElement("a");
          a.href = data.downloadUrl;
          a.download = data.fileName || "wiki-backup.zip";
          document.body.appendChild(a);
          a.click();
          a.remove();
        }
      } else {
        const file = form.elements.backupFile?.files?.[0];
        if (!file) { say("Bitte Backup-Datei wählen."); return; }
        if (String(form.elements.confirm?.value || "").trim().toUpperCase() !== "ÜBERSCHREIBEN" && String(form.elements.confirm?.value || "").trim().toUpperCase() !== "UEBERSCHREIBEN") {
          say("Bitte zur Bestätigung ÜBERSCHREIBEN eingeben.");
          return;
        }
        say("Wiederherstellung läuft ...");
        const buf = await file.arrayBuffer();
        let binary = "";
        const bytes = new Uint8Array(buf);
        for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
        const data = await apiRequest("/api/backup/restore", { method: "POST", body: JSON.stringify({ fileName: file.name, data: btoa(binary) }) });
        await refreshFromServer(data);
        await loadSuggestions().catch(() => {});
        say(`Wiederherstellung erfolgreich: ${data.restoredArticles || 0} Artikel, ${data.restoredImages || 0} Bilder.`);
        render();
      }
    } catch (error) {
      say(error.message || (mode === "create" ? "Backup fehlgeschlagen." : "Wiederherstellung fehlgeschlagen."));
    } finally {
      state.backupBusy = false;
      if (progress) progress.hidden = true;
      if (submit) submit.disabled = false;
    }
  }

  if (els.copy) els.copy.hidden = true;
  if (els.print) els.print.hidden = true;
  if (els.copy) els.copy.addEventListener("click", async () => {
    const href = location.href;
    try {
      await navigator.clipboard.writeText(href);
      setStatus("Link kopiert.");
    } catch (_) {
      window.prompt("Link kopieren", href);
    }
  });

  if (els.print) els.print.addEventListener("click", () => window.print());
  if (els.optionsCopy) els.optionsCopy.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(location.href); setStatus("Link kopiert."); }
    catch (_) { window.prompt("Link kopieren", location.href); }
    document.getElementById("optionsMenu")?.removeAttribute("open");
  });
  if (els.optionsPrint) els.optionsPrint.addEventListener("click", () => {
    window.print();
    document.getElementById("optionsMenu")?.removeAttribute("open");
  });
  if (els.optionsBackupCreate) els.optionsBackupCreate.addEventListener("click", () => openBackupDialog("create"));
  if (els.optionsBackupRestore) els.optionsBackupRestore.addEventListener("click", () => openBackupDialog("restore"));

  // Punkt 8: Bilder per Drag&Drop / Zwischenablage (Screenshot, Strg+V) direkt hochladen.
  document.addEventListener("paste", (event) => {
    const visual = event.target && event.target.closest ? event.target.closest("[data-visual-input]") : null;
    if (!visual) return;
    const editor = visual.closest("[data-markdown-editor]");
    const files = event.clipboardData ? Array.from(event.clipboardData.files || []).filter((f) => f.type.startsWith("image/")) : [];
    if (!files.length || !editor) return;
    event.preventDefault();
    uploadEditorImage(editor, files[0]).catch((error) => setStatus(error.message || "Bild konnte nicht eingefügt werden."));
  });
  document.addEventListener("drop", (event) => {
    const visual = event.target && event.target.closest ? event.target.closest("[data-visual-input]") : null;
    if (!visual) return;
    const editor = visual.closest("[data-markdown-editor]");
    const files = event.dataTransfer ? Array.from(event.dataTransfer.files || []).filter((f) => f.type.startsWith("image/")) : [];
    if (!files.length || !editor) return;
    event.preventDefault();
    uploadEditorImage(editor, files[0]).catch((error) => setStatus(error.message || "Bild konnte nicht eingefügt werden."));
  });
  document.addEventListener("submit", (event) => {
    if (event.target && event.target.id === "backupForm") {
      event.preventDefault();
      handleBackupSubmit(event.target);
    }
  });
  document.addEventListener("click", (event) => {
    if (event.target && event.target.closest && event.target.closest("[data-close-backup]")) {
      document.getElementById("backupDialog")?.close();
      document.getElementById("backupDialog")?.remove();
    }
  });
  // Vorschlags-Ampel aktuell halten (alle Rollen mit Vorschlagszugriff).
  setInterval(() => {
    if (state.user && (can("articles.suggest") || can("articles.edit")) && !document.hidden) loadSuggestions().catch(() => {});
  }, 30000);
  window.addEventListener("hashchange", () => {
    // P9: Rueckkehr nach abgebrochenem Verlassen (Dirty-Guard) rendert nicht neu,
    // damit ungespeicherte Editor-Inhalte erhalten bleiben.
    if (state.dirtyGuardReturn) {
      state.dirtyGuardReturn = false;
      return;
    }
    // P9: Ungespeicherte Editor-Aenderungen beim Verlassen der Seite abfangen.
    if (state.editorDirty && !isEditorRoute()) {
      if (window.confirm("Ungespeicherte Aenderungen verwerfen?")) {
        state.editorDirty = false;
      } else {
        state.dirtyGuardReturn = true;
        history.back();
        return;
      }
    }
    if (state.currentLockSlug && getCurrentSlug() !== state.currentLockSlug) releaseArticleLock();
    render();
  });
  window.addEventListener("beforeunload", (event) => {
    if (state.editorDirty) event.preventDefault();
  });

  applyTheme();
  detectEditor();
})();
