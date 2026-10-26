import Foundation

/// The agent's eyes (ITER-074 §6.1): one JavaScript expression the app runs in
/// a tab it owns. It returns a JSON string describing every element a person
/// could act on. No model ever writes or edits this script.
///
/// It runs in the page's own world, so a page can break it or feed it lies —
/// the page controls `JSON`, `Array.prototype` and the DOM it reads. The report
/// is therefore data and nothing more: it is decoded strictly and size-capped
/// (`ObservedPage.decode`), a broken one is refused, and no safety decision
/// rests on a page telling the truth about itself (§7.3).
///
/// Known limit: "on screen" is decided by hit-testing, and hit-testing skips
/// layers with `pointer-events: none` (WebKit's `elementsFromPoint` too,
/// checked 2026-09-24). A page can cover a clickable element with such a layer
/// and it still reads as on screen. Finding those layers would mean computing
/// the style of every element on the page; the cost is not paid, because
/// anything irreversible behind such a layer still needs the user's yes for
/// that exact, named action (§7.1).
enum ObserverScript {
    /// The most elements one observation reports. A page with more sets
    /// `truncated`; candidates are then built from what was seen (§6.2).
    static let maxElements = 500

    /// The longest address the report carries; `MAX_URL` in the script.
    /// An address this long may have been cut, so two of them are not proof
    /// of the same destination (§6.3).
    static let maxURLLength = 2000

    /// The walk the observer and the action scripts share: its limits, the
    /// text helpers, and `observe()`, which returns the report and, beside
    /// it, the nodes the report describes, in the same order.
    ///
    /// `observe()` walks the document once, in document order, and reports
    /// every visible actionable element: role, accessible name, visible text,
    /// where activating it leads (its own href, or the link around it), input
    /// type, nearest visible heading, the row it sits in, page region and
    /// whether a person can see it right now.
    ///
    /// Bounded everywhere: elements, nodes, headings, nodes and text walked
    /// per element and for the excerpt — a walk takes no more of a node's
    /// children than it may still visit — options per select (1000) and per
    /// page (2000), total time, string lengths — except the words that say
    /// what a field asks for, which are read whole within the time budget.
    ///
    /// Names follow the accessible-name order: `aria-labelledby` (its labels
    /// count even when hidden), `aria-label`, a picture's own `alt` or an
    /// svg's own `title`, the field's own labels, an input button's value —
    /// or, with none, the English word browsers show, "Submit" or "Reset",
    /// which names that button and never its form — the element's visible
    /// content (never for a field — what someone typed stays out), then
    /// `title` (never for a custom select, whose title is its choice) and
    /// `placeholder` as last resorts — and, for a field none of them names,
    /// the words a person reads before it in its own group (2026-10-21: a
    /// practice form's `<label>`s are tied to no field): up through at most
    /// six boxes that hold no other field, the first that shows any — a label
    /// tied to no field, a placeholder a widget draws, its row's caption —
    /// else the words on its own line before it, or on the line above when it
    /// starts its line; for a box or a radio, the words drawn right after it
    /// on its line (a practice form in a table). Never a hint after a field,
    /// words hidden from sight, another control's, an announcement's or a
    /// list's, and never for a secret field or one switched off
    /// (`lastWordsOf`). Content is read as a person hears it: a
    /// part's `aria-label`, a picture's `alt` or an svg's `title` stands for
    /// that part, and a part hidden from assistive technology, or a field
    /// inside, says nothing. The role is the first ARIA role the element
    /// names that ARIA recognises; a non-interactive one ("heading") means it
    /// is not a control.
    ///
    /// Jev sees what a person sees (owner decision of 2026-10-03). The only
    /// secret fields are the ones the page marks secret by its structure,
    /// decided in one place (`markedSecret`): `type=password`; an
    /// `autocomplete` of `current-password`, `new-password`, `one-time-code`
    /// or `cc-*`; dots drawn by `-webkit-text-security` — and an editor with
    /// such a field inside. Shown or hidden, they are never reported: not
    /// what they hold, nor what is drawn inside them, nor the lists they name
    /// as their own; a password or card field flags the page (`loginForm`,
    /// `paymentForm`). A field once secret stays secret for the life of the
    /// document, as the kind of secret it was, and a name it had only in its
    /// own form. A field's words never hide it: the words that name a sign-in
    /// or a payment — `<label>`, `aria-labelledby`, `aria-label`, `title`,
    /// `name`, `placeholder`, read whole — only say what the page asks for,
    /// the flags and the forms that could send a secret; so does a card
    /// number a field holds, alone or split over a form's fields. No text the
    /// report carries is hidden: it is read as a person reads it, its
    /// compatibility forms and invisible marks as plain text; `url` is the
    /// address others may see — as the address bar shows it, with no user
    /// name or password — and `address` where the tab really is. A hidden
    /// input is never read.
    /// Every other field reports what it holds as its `value` (owner decision
    /// 4, replacing ITER-076 2.3's "no value ever"): a native field's value, a
    /// select's chosen option, an editable region's words, bounded, and never
    /// as a name, text, row or heading. The choice a custom select (a
    /// `combobox`, or a list box that pops up as one) draws is still no word
    /// of any control: neither its words nor a control it draws inside itself;
    /// only its options, list boxes, tree items and real fields are controls,
    /// and a field there is checked for a secret like any other. Known limit:
    /// that drawn choice is not its value either. Whether a value held is
    /// checked in the page itself (`ActionScript.holds`). Whether a checkbox,
    /// radio or switch is on is reported (`checked`). Each control says whether
    /// acting on it could send a secret field (`touchesSecret`), and whether
    /// its form or its page region shows a money amount (`showsAmount`,
    /// owner decision 6). Each has a private `key`, the same for the
    /// document's life, which only the hands read.
    ///
    /// Known limits (ITER-076 2.3): a custom select drawn as a plain button,
    /// with no `combobox` role, shows its choice as the button's own words,
    /// and they are its name; one whose `combobox` role sits on its input
    /// (react-select) draws its choice beside it, where it reads as any text
    /// — and, drawn before its input where its placeholder was, names it when
    /// nothing else does (2026-10-21).
    /// A button drawn inside a combobox wrapper (a search or clear button in
    /// the ARIA 1.1 layout) is part of the select, and is not offered.
    ///
    /// ITER-076 I-08, ported from a reference browser agent: an anchor with no
    /// address but a handler is a button; a plain label stands for the
    /// see-through checkbox or radio it labels — reported as that input where
    /// the label is — and a see-through one with no label a person sees is
    /// reported itself, named by its role when it has no name. A checkbox or
    /// radio is never a secret field. Each control says whether a click opens
    /// it (`opens`) and whether a click may send a form that needs a file
    /// (`needsFile`); an option, which made-up dropdown's list holds it
    /// (`listOf`), who that dropdown is (`listOwner`), and the form it sends
    /// (`listForm`), kept beside the one the option is drawn in. What a secret
    /// field — or anything inside it — names as its own list is withheld with
    /// it. The choice a made-up dropdown shows still reaches no report: the
    /// hands read it back in the page (`choiceShown`).
    ///
    /// Where someone writes — a textarea, a select, an editable region, an
    /// element whose own role is a text field — only the field itself is
    /// reported, and nothing written there becomes any element's name, text,
    /// row context or heading. That is judged on the tree a person sees:
    /// slots and shadow roots included.
    ///
    /// Form controls carry their form's destination, method and submit label,
    /// read through the form's own getters so a control named "action"
    /// cannot rewrite them. Open shadow roots are walked, with their labels
    /// resolved in their own tree; closed ones cannot be.
    ///
    /// Frames (review of A3d, round 2, P1-5): no control inside a frame is
    /// reported, but a frame of the page's own origin is read for secret
    /// fields — in a form, its form holds them; in none, they are secrets
    /// outside any form — and a frame of another origin inside a form makes
    /// what that form holds unknown, which counts as a secret. Known limit: a
    /// frame of another origin outside any form is not read; a hosted payment
    /// form there flags the page by its provider's host only.
    ///
    /// Every run of it also keeps the page's quiet clock (`quietClock`), so the
    /// clock runs before the agent acts (ITER-076 I-07).
    static let walk = quietClock + ownTitle + #"""
    const MAX_ELEMENTS = 500, MAX_NODES = 5000, MAX_HEADINGS = 1000, TIME_BUDGET_MS = 1000;
    const MAX_TEXT = \#(maxName), MAX_CONTEXT = \#(maxContext), MAX_URL = \#(maxURLLength), MAX_TEXT_NODES = 400;
    const MAX_WALK = 1000, MAX_OPTIONS = 1000, MAX_PAGE_OPTIONS = 2000, MAX_EXCERPT_NODES = 20000;
    const MAX_PAGE_TEXT = \#(ObservedPage.maxText);
    const MAX_CENSUS = 100000;
    const squeeze = (value) => String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
    // What a page may put inside a word to change how a check reads it —
    // compatibility forms of digits and letters (full-width "４１１１"),
    // zero-width spaces and joiners, a soft hyphen — is read as the plain
    // text it stands for: every string the report carries, and every
    // comparison of one, reads so.
    const normalizeSecrets = (text) => String(text).normalize('NFKC').replace(/[\#(SafetyGuard.invisibleMarks)]/g, '');
    const luhn = (digits) => {
      let sum = 0;
      for (let i = 0; i < digits.length; i++) {
        let digit = digits.charCodeAt(digits.length - 1 - i) - 48;
        if (i % 2 === 1) { digit *= 2; if (digit > 9) digit -= 9; }
        sum += digit;
      }
      return sum % 10 === 0;
    };
    // Whether a text holds a card number: a run of digit groups, parted by
    // spaces, dots, dashes, slashes or underscores, from any group on 13 to
    // 19 digits that pass the Luhn check ("4111 1111 1111 1111 22" holds one
    // though the whole run does not pass). What a field's payment is known
    // by — never what is hidden: a person sees it (owner decision of
    // 2026-10-03).
    const holdsCardNumber = (text) => {
      const digitRuns = /\d[\d ._\/-]*\d/g;
      for (let match; (match = digitRuns.exec(text)) !== null;) {
        const groups = match[0].match(/\d+/g);
        for (let start = 0; start < groups.length; start++) {
          let digits = '';
          for (let end = start; end < groups.length && digits.length < 19; end++) {
            digits += groups[end];
            if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) return true;
          }
        }
      }
      return false;
    };
    // Where one text node meets the next. The page may draw a seam as a
    // break ("Enter" | "OTP" on two lines) or as nothing ("Pass" | "word"),
    // so the words are matched both ways at once (see `standingAlone`).
    const SEAM = String.fromCharCode(0x200B);
    // Words that name a secret only standing alone — "otp", never "hotpot".
    // Each end is a space, the edge or a seam, and a seam inside is read as
    // nothing, so every way the page may draw its seams counts without
    // trying each one.
    const standingAlone = (list) => new RegExp('(?:^|[ ' + SEAM + '])(?:' +
      list.map((word) => Array.from(word).join(SEAM + '?')).join('|') + ')(?=$|[ ' + SEAM + '])', 'iu');
    // Words that name a password or a sign-in code wherever they stand,
    // inside a longer word too ("Passwort"): matched on the words read run
    // together, so none of them may ask for a word end — a seam there is
    // read as nothing. Only a field's words are read with them, to say what
    // it asks for — a sign-in, the user's part — never to hide anything
    // (owner decision of 2026-10-03): a one-time, verification,
    // confirmation, security, backup, recovery, access, auth, authenticator,
    // login or sign-in code, a passcode (`codePhrases`); a PIN, an OTP, 2FA
    // (`passwordShortWords`). A field's words never read "code" alone, so
    // "Postal code" names no sign-in (ITER-076 I-09, review round 4,
    // decision 2).
    const passwordPhrases = /(passw|passphrase|one.?time.?pass|two.?factor)/i;
    const codePhrases = /((one.?time|verification|confirmation|security|backup|recovery|access|log.?in|sign.?in|auth(entication|enticator)?(.?app)?).?codes?|passcode)/i;
    const passwordShortWords = standingAlone(['pwd', 'otp', '2fa', 'pin']);
    // A 64-bit digest of a text, exact to the last character and space: what
    // an option is known by again, without its words or value leaving the
    // page (review of I-02, N3-P2-1).
    const digestOf = (text) => {
      let a = 0xdeadbeef, b = 0x41c6ce57;
      const whole = String(text);
      for (let i = 0; i < whole.length; i++) {
        const unit = whole.charCodeAt(i);
        a = Math.imul(a ^ unit, 2654435761);
        b = Math.imul(b ^ unit, 1597334677);
      }
      a = Math.imul(a ^ (a >>> 16), 2246822507) ^ Math.imul(b ^ (b >>> 13), 3266489909);
      b = Math.imul(b ^ (b >>> 16), 2246822507) ^ Math.imul(a ^ (a >>> 13), 3266489909);
      return (b >>> 0).toString(16).padStart(8, '0') + (a >>> 0).toString(16).padStart(8, '0');
    };
    // What an option is: its exact words and value, digested.
    const optionKeyOf = (option) => digestOf(String(option.text) + '\u0000' + String(option.value));
    // Every string the report carries, as a person reads it — its spaces
    // squeezed, read as plain text (`normalizeSecrets`) — then cut; nothing
    // in it is hidden (owner decision of 2026-10-03). Comparisons read
    // strings the same way.
    const ownMasked = (value) => normalizeSecrets(squeeze(value));
    const collapse = (value) => ownMasked(value).slice(0, MAX_TEXT);
    // An address as anyone but the app may see it: as the address bar shows
    // it, with no user name or password, which a browser never shows (owner
    // decision of 2026-10-03). A page can break `URL` in its own world: then
    // nothing past the path is shown, and no user name or password either.
    const addressMasked = (href) => {
      const raw = String(href);
      try {
        const url = new URL(raw);
        url.username = '';
        url.password = '';
        return String(url.toString());
      } catch (error) {
        return raw.split(/[?#]/)[0].replace(/^([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^\/@]*@/, '$1');
      }
    };
    // What a control is, and the parent a person sees: the observer's, and
    // the agent's hands' when they check where a click lands. An anchor with
    // no address that the page's one handler answers — a date picker's — is
    // one too (ITER-076 I-08, a reference browser agent's `SELECTOR`).
    const interactiveRoles = ['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem',
      'menuitemcheckbox', 'menuitemradio', 'option', 'slider', 'spinbutton', 'textbox',
      'searchbox', 'combobox', 'listbox', 'treeitem'];
    const selector = ['a[href]', 'a[data-handler][data-event="click"]', 'button', 'input:not([type=hidden])', 'select',
      'textarea', '[onclick]', '[contenteditable]:not([contenteditable=false])', 'summary']
      .concat(interactiveRoles.map((role) => '[role~="' + role + '"]'))
      .join(', ');
    // A styled checkbox or radio often hides its native input: its label is
    // then what a person clicks, while the input keeps the checked and
    // disabled state (ITER-076 I-08, a reference browser agent's
    // `nativeChoice` and `sourceOf`). What a plain label stands for: the
    // checkbox or radio it labels, read through the label's own getter. A
    // label with a handler of its own — `onclick`, a role, a `data-handler` —
    // stands for itself, the control it was: what its click does is its own
    // (review of I-08, F3). Anything else stands for itself.
    const nativeChoice = (el) => el instanceof HTMLInputElement && ['checkbox', 'radio'].includes((el.type || '').toLowerCase());
    const labelControl = Object.getOwnPropertyDescriptor(HTMLLabelElement.prototype, 'control').get;
    const sourceOf = (el) => {
      if (!(el instanceof HTMLLabelElement) || ['onclick', 'role', 'data-handler'].some((name) => el.hasAttribute(name))) {
        return el;
      }
      const control = labelControl.call(el);
      return control && nativeChoice(control) ? control : el;
    };
    // The parent a person sees: a slotted element sits in its slot, the top
    // of a shadow root under its host. For position, headings and regions
    // an element inside a shadow root answers to its outermost host.
    const composedParent = (el) => {
      if (el.assignedSlot) return el.assignedSlot;
      if (el.parentElement) return el.parentElement;
      const root = el.getRootNode();
      return root instanceof ShadowRoot ? root.host : null;
    };
    // The lists an element names as its own by `aria-controls` and
    // `aria-owns`, found in its own tree first, then the document (ITER-076
    // I-08) — every one, each once (Claude review of I-09, kept 15). An
    // element that names more than `MAX_NAMED_LISTS` gives null: no widget a
    // person uses names that many parts, and who owns what is then unknown —
    // never a list left out unsaid (Codex review 1 of I-09, P1-2). The bound
    // keeps one element's names from taking the walk's time; the census bounds
    // the rest. The observer's walks, its claims and the hands' typing read
    // this one answer.
    const MAX_NAMED_LISTS = 64;
    const listsNamedBy = (node) => {
      const ids = new Set(((node.getAttribute('aria-controls') || '') + ' ' + (node.getAttribute('aria-owns') || ''))
        .split(/\s+/).filter(Boolean));
      if (ids.size > MAX_NAMED_LISTS) return null;
      const root = node.getRootNode();
      const lists = new Set();
      for (const id of ids) {
        const list = (typeof root.getElementById === 'function' ? root.getElementById(id) : null) ||
          document.getElementById(id);
        if (list) lists.add(list);
      }
      return Array.from(lists);
    };
    // `options.excerpt` with `options.alone`: only the writer's excerpt, of
    // at most that many characters, the page's address and title.
    const observe = (options) => {
      const started = performance.now();
      const late = () => performance.now() - started > TIME_BUDGET_MS;

      // Every non-abstract WAI-ARIA 1.2 role: the first of these an element
      // names is its role, interactive or not.
      const knownRoles = interactiveRoles.concat(['alert', 'alertdialog', 'application', 'article',
        'banner', 'blockquote', 'caption', 'cell', 'code', 'columnheader', 'complementary',
        'contentinfo', 'definition', 'deletion', 'dialog', 'directory', 'document', 'emphasis',
        'feed', 'figure', 'form', 'generic', 'grid', 'gridcell', 'group', 'heading', 'img',
        'insertion', 'list', 'listitem', 'log', 'main', 'marquee', 'math', 'meter', 'menu',
        'menubar', 'navigation', 'none', 'note', 'paragraph', 'presentation', 'progressbar',
        'radiogroup', 'region', 'row', 'rowgroup', 'rowheader', 'scrollbar', 'search',
        'separator', 'status', 'strong', 'subscript', 'superscript', 'table', 'tablist',
        'tabpanel', 'term', 'time', 'timer', 'toolbar', 'tooltip', 'tree', 'treegrid']);
      const fieldRoles = ['textbox', 'searchbox', 'combobox', 'listbox', 'spinbutton', 'slider'];

      const anchorOf = (node) => {
        let current = node;
        for (let hops = 0; hops < 20; hops++) {
          const root = current.getRootNode();
          if (!(root instanceof ShadowRoot)) break;
          current = root.host;
        }
        return current;
      };

      const styles = new Map();
      const styleOf = (el) => {
        let style = styles.get(el);
        if (!style) { style = getComputedStyle(el); styles.set(el, style); }
        return style;
      };

      // A see-through native checkbox or radio that takes the pointer and has
      // no label of its own a person sees is the one control its row shows —
      // a to-do list's box: its own opacity is excused, a see-through
      // parent's is not, and one switched off is not shown (ITER-076 I-08, a
      // reference browser agent's `visible`).
      const seeThroughChoice = (node) => nativeChoice(node) && styleOf(node).pointerEvents !== 'none' &&
        !node.matches(':disabled') && !node.closest('[aria-disabled="true"]') &&
        !Array.from(node.labels || []).some((label) => visible(label));
      const visible = (node) => {
        if (node.getClientRects().length === 0) return false;
        const rect = node.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return false;
        const style = styleOf(node);
        if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
        for (let el = node; el && el.nodeType === 1; el = composedParent(el)) {
          const s = styleOf(el);
          if (s.display === 'none') return false;
          if (parseFloat(s.opacity) === 0 && !(el === node && seeThroughChoice(node))) return false;
        }
        return true;
      };

      const firstKnownRole = (node) => {
        const tokens = (node.getAttribute('role') || '').toLowerCase().split(/\s+/).filter(Boolean);
        return tokens.find((token) => knownRoles.includes(token)) || null;
      };

      // Where someone writes: a textarea, a select, an editable region, an
      // element whose own role is a text field. What sits inside — typed
      // text, a select's options, chips — is their writing: it reaches no
      // name, text, context or heading, and only the field itself is a
      // control. Judged on the tree a person sees: a chip a component draws
      // in its shadow root, or slots into its field, is inside that field.
      const writingRoles = ['textbox', 'searchbox', 'spinbutton'];
      const isWritingPlace = (el) => {
        const tag = el.tagName.toLowerCase();
        return tag === 'textarea' || tag === 'select' || el.isContentEditable === true ||
          writingRoles.includes(firstKnownRole(el));
      };
      const writing = new Map();
      const inWriting = (el) => {
        const path = [];
        let answer = false;
        for (let current = el; current; current = composedParent(current)) {
          const known = writing.get(current);
          if (known !== undefined) { answer = known; break; }
          path.push(current);
          if (isWritingPlace(current)) { answer = true; break; }
        }
        for (const visited of path) writing.set(visited, answer);
        return answer;
      };
      const insideWriting = (node) => {
        const parent = composedParent(node);
        return !!parent && inWriting(parent);
      };

      // Where a piece of text sits in the tree a person sees: the slot a
      // component puts it in, the host of the shadow root it stands in
      // directly, or else its parent. Null when it is not shown at all — a
      // component's own text that no slot takes.
      const textPlace = (textNode) => {
        if (textNode.assignedSlot) return textNode.assignedSlot;
        const parent = textNode.parentNode;
        if (parent instanceof ShadowRoot) return parent.host;
        return parent && parent.nodeType === 1 && !parent.shadowRoot ? parent : null;
      };
      // A custom select: a combobox, or a list box that pops up as one does.
      // A list box that is a plain list is not.
      const isChoiceWidget = (el) => {
        const role = firstKnownRole(el);
        if (role === 'combobox') return true;
        if (role !== 'listbox') return false;
        const popup = (el.getAttribute('aria-haspopup') || 'false').trim().toLowerCase();
        return el.hasAttribute('aria-expanded') || popup !== 'false';
      };
      // Where someone types or picks: a text field, a select, an editable
      // region.
      const nonEntryTypes = ['button', 'submit', 'reset', 'image', 'checkbox', 'radio'];
      const isEntryField = (el) => {
        const tag = el.localName;
        if (tag === 'textarea' || tag === 'select' || el.isContentEditable === true) return true;
        return tag === 'input' && !nonEntryTypes.includes((el.type || 'text').toLowerCase());
      };
      // What a custom select draws inside itself is part of it — a read-only
      // box that shows the choice, a button that removes it — but not its
      // options, list boxes and tree items, nor a real field inside it (the
      // ARIA 1.1 layout), which is checked for a secret like any field.
      const drawnByChoice = (el) =>
        !isEntryField(el) && !['option', 'listbox', 'treeitem'].includes(firstKnownRole(el));
      // A custom select shows its choice as its own text, and that text is
      // its value: words whose nearest control is a custom select never
      // count (ITER-076 2.3). Decided top down, without recursion: a control
      // decides for what it holds, unless it is one a select draws inside
      // itself, which is looked past. An option keeps its own words.
      const choices = new Map();
      const showsChoice = (el) => {
        const path = [];
        let answer = false;
        for (let current = el; current; current = composedParent(current)) {
          const known = choices.get(current);
          if (known !== undefined) { answer = known; break; }
          path.push(current);
        }
        for (let i = path.length - 1; i >= 0; i--) {
          const node = path[i];
          if (node.matches(selector) && !(answer && drawnByChoice(node))) answer = isChoiceWidget(node);
          choices.set(node, answer);
        }
        return answer;
      };
      const insideChoice = (node) => {
        const parent = composedParent(node);
        return !!parent && showsChoice(parent) && drawnByChoice(node);
      };
      // The box a place is drawn in: itself, or — for a slot or anything else
      // that draws no box of its own (display: contents) — the nearest
      // element above it that does (ITER-076 2.3).
      const drawnBox = (el) => {
        let current = el;
        for (let hops = 0; current && hops < 20 && styleOf(current).display === 'contents'; hops++) {
          current = composedParent(current);
        }
        return current;
      };

      // The fields the visible walk found sensitive: the report leaves them
      // out and the page's flags count them.
      const sensitive = new Set();
      // Whether an element is a field the page marks secret by its structure
      // (`markedSecret`) — shown or hidden, because a hidden field's words can
      // still be read into another element's name.
      const markedFields = new Map();
      // A field, as every check for a secret field reads one: it holds text,
      // and is one by its tag or by the role it plays — an editable region
      // included.
      const isField = (el) => holdsText(el) && (fieldTags.includes(el.localName) || fieldRoles.includes(roleOf(el)));
      const sensitiveField = (el) => {
        if (markedFields.has(el)) return markedFields.get(el);
        const answer = isField(el) && markedSecret(el);
        markedFields.set(el, answer);
        return answer;
      };
      // What a sensitive field holds never becomes any text the walk reports,
      // nor what the lists it names as its own hold: its suggestions drawn
      // anywhere on the page (review of I-08, F4).
      const secretLists = new Set();
      // When the fields the page marks secret could not all be found — the
      // page's trees too many to count, or out of time — any list may be
      // one's: every list or option by its role, and anything a name can
      // point to — an element with an id — is held as one (Codex review 2 of
      // I-08, P1-1; Codex review 3 of I-08, P1-1).
      let listsUnknown = false;
      const listRoles = ['listbox', 'option', 'treeitem'];
      const mayBeSecretList = (el) => secretLists.has(el) ||
        (listsUnknown && (listRoles.includes(firstKnownRole(el)) || !!el.id));
      const insideSensitive = (el) => {
        for (let current = el; current; current = composedParent(current)) {
          if (sensitive.has(current) || sensitiveField(current) || mayBeSecretList(current)) return true;
        }
        return false;
      };
      // A control inside a sensitive field is part of it: only the field is
      // judged, and it is not reported at all.
      const insideSensitiveField = (node) => {
        const parent = composedParent(node);
        return !!parent && insideSensitive(parent);
      };

      // Whether words at a place reach the report: not someone's writing,
      // not inside a sensitive field, not a custom select's choice, not drawn
      // as dots, all a person sees of them (Claude review c11, #1), and —
      // unless hidden words count — drawn where a person can see them. The
      // rule that keeps them out, by its name — the reader's read counts
      // them (ITER-076 stage 4a) — or null when they reach it.
      const unreadableBecause = (place, withHidden) => {
        if (inWriting(place)) return 'writing';
        if (insideSensitive(place)) return 'secret';
        if (showsChoice(place)) return 'choice';
        if (masksItsText(place)) return 'dots';
        if (withHidden) return null;
        const box = drawnBox(place);
        if (!box || box.getClientRects().length === 0) return 'undrawn';
        const style = styleOf(place);
        return style.visibility !== 'hidden' && style.visibility !== 'collapse' ? null : 'hidden';
      };
      const readable = (place, withHidden) => unreadableBecause(place, withHidden) === null;

      // What a part of a control says when the control's name is read from
      // its content: nothing when it is hidden from assistive technology,
      // unreadable, or a field — whose value is never read; else its
      // `aria-label`, a picture's `alt` or an svg's `title`. Null: read its
      // content instead.
      const alternativeOf = (el, withHidden) => {
        if (el.getAttribute('aria-hidden') === 'true') return '';
        if (fieldTags.includes(el.localName) || fieldRoles.includes(firstKnownRole(el))) return '';
        const label = (el.getAttribute('aria-label') || '').trim();
        const title = svgTitle(el);
        if (!label && el.localName !== 'img' && title === null) return null;
        if (!readable(el, withHidden)) return '';
        if (label) return label;
        return el.localName === 'img' ? (el.getAttribute('alt') || '') : title;
      };
      // An svg's own title, its first `<title>` child; null for anything else.
      const svgTitle = (el) => {
        if (el.localName !== 'svg') return null;
        const title = el.querySelector(':scope > title');
        return title ? (title.textContent || '') : null;
      };

      // A node's drawn children, pushed for a walk that takes the last pushed
      // first — at most the first `room` of them: a walk that may visit only
      // `room` more nodes never reaches the others. True when some were left
      // out: that walk did not read its node whole.
      const pushDrawnChildren = (stack, node, room) => {
        const children = drawnChildren(node);
        for (let i = Math.min(children.length, Math.max(0, room)) - 1; i >= 0; i--) stack.push(children[i]);
        return children.length > Math.max(0, room);
      };

      // Text of an element on the tree a person sees — a component's shadow
      // root, and the words its slots show (ITER-076 2.3, S4) — walked node
      // by node and stopped at a bound on nodes and on text, so one huge
      // element cannot take the whole budget. Words `readable` refuses never
      // count; hidden ones count only `withHidden`: the words that name a
      // field count whether they are shown or not. `asName` reads it as a
      // name is read from content (`alternativeOf`).
      const TEXT_READ = MAX_TEXT * 2;
      // `leaveOut`: parts whose words do not count at all. `until`: a node
      // inside `el` where the reading ends — only the words before it count —
      // and every part around it is read into, whatever it stands for
      // (2026-10-21).
      const boundedText = (el, withHidden, asName, leaveOut, until) => {
        if (!el) return '';
        let around = null;
        if (until) {
          around = new Set();
          for (let part = composedParent(until); part && part !== el; part = composedParent(part)) around.add(part);
        }
        const stack = [el];
        let out = '';
        const add = (text) => {
          out += text.slice(0, Math.max(0, TEXT_READ - out.length));
        };
        for (let walked = 0, texts = 0; stack.length > 0; walked++) {
          if (walked >= MAX_WALK || texts >= MAX_TEXT_NODES || out.length >= TEXT_READ || late()) break;
          const node = stack.pop();
          if (node === until) break;
          if (node.nodeType === 3) {
            texts++;
            const place = textPlace(node);
            if (place && readable(place, withHidden)) add(' ' + String(node.nodeValue));
            continue;
          }
          const whole = node === el || (around !== null && around.has(node));
          // Nothing inside an element that is not drawn is shown.
          if (!withHidden && !whole && node.nodeType === 1 && styleOf(node).display === 'none') continue;
          if (leaveOut && !whole && leaveOut.has(node)) continue;
          if (asName && !whole && node.nodeType === 1) {
            const alternative = alternativeOf(node, withHidden);
            if (alternative !== null) {
              add(' ' + alternative);
              continue;
            }
          }
          pushDrawnChildren(stack, node, MAX_WALK - walked - 1);
        }
        return ownMasked(out);
      };


      // A link that acts through the page's own script (ITER-076 I-10, critic
      // 12): its address, as the browser reads it — tabs and line breaks
      // inside dropped, spaces at its ends trimmed — is empty, "#", or a
      // `javascript:` one. It goes nowhere: it is a button, and a click runs
      // its script.
      const scriptLink = (node) => {
        if (node.localName !== 'a' || !node.hasAttribute('href')) return false;
        const written = String(Element.prototype.getAttribute.call(node, 'href'))
          .replace(/[\t\n\r]/g, '').replace(/^[\u0000-\u0020]+|[\u0000-\u0020]+$/g, '');
        return written === '' || written === '#' || /^javascript:/i.test(written);
      };

      // null means: not a control. A label that stands for its checkbox or
      // radio is that input (ITER-076 I-08), with the role the input has
      // itself — its own ARIA role, else its type — whichever of the two a
      // person clicks (Codex review 1 of I-08, P2-6).
      const roleOf = (node) => {
        const source = sourceOf(node);
        if (source !== node) return roleOf(source);
        const explicit = firstKnownRole(node);
        if (explicit) {
          if (interactiveRoles.includes(explicit)) return explicit;
          return node.hasAttribute('onclick') ? 'button' : null;
        }
        const tag = node.tagName.toLowerCase();
        // An address is what makes an anchor a link: one with nowhere to go
        // acts through its click handler alone, as a button (ITER-076 I-08, a
        // reference browser agent's `roleOf`) — and so does one whose address
        // is its script (ITER-076 I-10).
        if (tag === 'a') return node.hasAttribute('href') && !scriptLink(node) ? 'link' : 'button';
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'select') return node.multiple ? 'listbox' : 'combobox';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
          const type = (node.type || 'text').toLowerCase();
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
          if (type === 'search') return 'searchbox';
          if (type === 'number') return 'spinbutton';
          if (type === 'range') return 'slider';
          return 'textbox';
        }
        if (node.isContentEditable) return 'textbox';
        return 'button';
      };

      // The elements aria-labelledby points to, resolved in the control's
      // own tree: a shadow root's ids are not the document's.
      const labelsByReference = (node) => {
        const root = node.getRootNode();
        const byId = (id) => (typeof root.getElementById === 'function' ? root.getElementById(id) : document.getElementById(id));
        return (node.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean).map(byId).filter(Boolean);
      };
      // As a name, the first five count — even when hidden, as the
      // accessible-name rules say.
      const labelledByText = (node) =>
        labelsByReference(node).slice(0, 5).map((label) => boundedText(label, true, true)).join(' ');

      // The words a person reads before a field in its own group (2026-10-21:
      // a practice form's captions are `<label>`s tied to no field, its select
      // boxes drawn around a combobox input; unnamed, its date field and its
      // subjects box had twins the hands refuse, and the brain could not tell
      // them apart): up from the field, through at most `GROUP_LEVELS` boxes —
      // that form's select box has its row's caption six boxes above its
      // input — the first box that shows words before the field names it: a
      // label tied to no field, a placeholder its widget draws, its row's
      // caption. A box that holds another field — one that draws a box, even
      // hidden from sight — or a frame, whose fields are not known, ends the
      // walk with no name, as does a section of the page, by its tag or its
      // role, a control, a label of a control, an announcement or a list, and
      // a page the walk did not read whole. What comes after the field — a
      // hint, a unit, the calendar it opens — never names it; nor do words
      // hidden from sight — not drawn, hidden or see-through — another
      // control's — a list box's and its options' among them — a label's of a
      // control, an announcement's (`aria-live`, a status, a log), or those of
      // a list the field names as its own: the tags it holds.
      const GROUP_LEVELS = 6;
      const sectionRoles = ['main', 'article', 'region', 'complementary', 'navigation', 'banner', 'contentinfo'];
      const announcingRoles = ['alert', 'log', 'marquee', 'status', 'timer'];
      const announces = (el) => announcingRoles.includes(firstKnownRole(el)) ||
        ['polite', 'assertive'].includes(String(el.getAttribute('aria-live') || '').trim().toLowerCase());
      // How many fields that draw a box, and frames, each box holds — two
      // meaning more than one — counted up from each one the walk found; null
      // when the walk was cut or ran out of time: what a box holds is not
      // known. Counted once a look, when a field first needs it.
      const countFieldsDrawn = () => {
        if (!walkedWhole) return null;
        const counts = new Map();
        for (const el of found.concat(pageFrames)) {
          if (late()) return null;
          if (!(holdsAFrame(el) || isEntryField(el) || fieldRoles.includes(firstKnownRole(el))) ||
              el.getClientRects().length === 0) continue;
          for (let part = composedParent(el); part; part = composedParent(part)) {
            const count = counts.get(part) || 0;
            if (count > 1) break;
            counts.set(part, count + 1);
          }
        }
        return counts;
      };
      let fieldsDrawn;
      const fieldsDrawnIn = (box) => {
        if (fieldsDrawn === undefined) fieldsDrawn = countFieldsDrawn();
        return fieldsDrawn ? (fieldsDrawn.get(box) || 0) : Infinity;
      };
      // Another control, or a label of one: its words are its own.
      const ownsItsWords = (el) => el.matches(selector) || (el instanceof HTMLLabelElement && !!labelControl.call(el));
      // Words that say what goes on, not what a control is: an
      // announcement's, a see-through part's, a list's the control names as
      // its own.
      const saysNoCaption = (el, ownLists) => announces(el) || ownLists.includes(el) ||
        parseFloat(styleOf(el).opacity) === 0;
      const groupWordsOf = (field, ownLists) => {
        const noCaption = (el) => el.nodeType === 1 && (ownsItsWords(el) || saysNoCaption(el, ownLists));
        const leaveOut = { has: noCaption };
        let box = composedParent(field);
        for (let level = 0; box && level < GROUP_LEVELS; level++, box = composedParent(box)) {
          if (SECTION_TAGS.includes(box.localName) || sectionRoles.includes(firstKnownRole(box)) || noCaption(box) ||
              fieldsDrawnIn(box) > 1) return '';
          const words = boundedText(box, false, true, leaveOut, field);
          if (words) return words;
        }
        return '';
      };
      // A box a line of words ends at: one not drawn inline.
      const isBlock = (el) => {
        const display = styleOf(el).display;
        return display !== 'none' && display !== 'contents' && !display.startsWith('inline');
      };
      // The words drawn beside a control on its own line (2026-10-21: a
      // practice form in a table names its boxes and radios only by the words
      // drawn right after each, and a field that shares its cell by the words
      // on the line above it; unnamed, its three boxes were twins the hands
      // refused): after a box or a radio; before a field — from the last
      // control, line break or block's edge before it, or, when it starts its
      // line, the line above. Up to the next control or label of one, line
      // break, block's edge or frame, never into one; words hidden from sight
      // or from assistive technology, an announcement's and a list's the
      // control names as its own are passed over. Bounded as a name.
      const lineWordsOf = (control, after, ownLists) => {
        // The node beside `node` on its line: its sibling, or its parent's
        // while the parent is drawn inline.
        const beside = (node) => {
          for (let current = node; current; current = current.parentNode) {
            const sibling = after ? current.nextSibling : current.previousSibling;
            if (sibling) return sibling;
            const parent = current.parentNode;
            if (!parent || parent.nodeType !== 1 || isBlock(parent) || ownsItsWords(parent)) return null;
          }
          return null;
        };
        const parts = [];
        let read = 0;
        let lineAbove = false;
        let node = beside(control);
        for (let walked = 0; node && walked < MAX_WALK && read < TEXT_READ && !late(); walked++) {
          if (node.nodeType === 3) {
            const place = textPlace(node);
            const words = String(node.nodeValue);
            if (place && readable(place, false) && /\S/.test(words)) {
              parts.push(words);
              read += words.length;
            }
            node = beside(node);
            continue;
          }
          if (node.nodeType !== 1 || styleOf(node).display === 'none' || node.getAttribute('aria-hidden') === 'true' ||
              saysNoCaption(node, ownLists)) {
            node = beside(node);
            continue;
          }
          if (node.localName === 'br') {
            if (after || parts.length > 0 || lineAbove) break;
            lineAbove = true;
            node = beside(node);
            continue;
          }
          if (ownsItsWords(node) || holdsAFrame(node) || isBlock(node)) break;
          const inside = node.childNodes;
          node = inside.length > 0 ? inside[after ? 0 : inside.length - 1] : beside(node);
        }
        return (after ? parts : parts.reverse()).join(' ');
      };
      // What names a control none of the accessible-name order names
      // (2026-10-21): a box's or a radio's own line after it; a field's own
      // group, else its own line before it. One switched off — itself or by
      // its fieldset — is named by none of them, as a select is by no role: it
      // stays unoffered (Codex review P2-5); and none when the lists it names
      // are past knowing.
      const lastWordsOf = (control) => {
        if (control.matches(':disabled')) return '';
        const ownLists = listsNamedBy(control);
        if (ownLists === null) return '';
        if (nativeChoice(control)) return lineWordsOf(control, true, ownLists);
        if (!isEntryField(control) && !fieldRoles.includes(firstKnownRole(control))) return '';
        return groupWordsOf(control, ownLists) || lineWordsOf(control, false, ownLists);
      };

      // An input button with no value shows the browser's own word.
      // It names that button only (`withDefaultWord`), never its form.
      const defaultButtonWords = { submit: 'Submit', reset: 'Reset' };
      const nameOf = (node, isField, withDefaultWord = true) => {
        const tag = node.tagName.toLowerCase();
        const inputType = (node.type || '').toLowerCase();
        const inputButton = tag === 'input' && ['button', 'submit', 'reset'].includes(inputType);
        // A custom select's title is the choice it shows (bootstrap-select).
        const showsItsChoice = isChoiceWidget(node);
        // Read in order, and only as far as the first that says anything.
        const candidates = [
          () => labelledByText(node),
          () => node.getAttribute('aria-label'),
          () => tag === 'img' ? node.getAttribute('alt') : (svgTitle(node) || ''),
          () => isField && node.labels
            ? Array.from(node.labels).slice(0, 3).map((label) => boundedText(label, false, true)).join(' ') : '',
          () => inputButton ? node.value : '',
          () => withDefaultWord && inputButton && !node.hasAttribute('value') ? (defaultButtonWords[inputType] || '') : '',
          () => tag === 'input' && inputType === 'image' ? node.getAttribute('alt') : '',
          () => isField ? '' : boundedText(node, false, true),
          () => showsItsChoice ? '' : node.getAttribute('title'),
          () => node.getAttribute('placeholder'),
          // A secret field's own group or line never names it: it is withheld.
          () => isField && !sensitive.has(node) ? lastWordsOf(node) : ''
        ];
        for (const candidate of candidates) {
          const value = ownMasked(candidate());
          if (value) return value;
        }
        return '';
      };

      // The row an element sits in, minus the element's own words: "Home"
      // for the "Remove" button in the Home row. A made-up dropdown's own
      // list and options say nothing about its row: open or closed, the row
      // reads the same (review of I-08, F5).
      const choiceLists = new Set();
      const contextOf = (node, ownText) => {
        const rowSelector = 'li, tr, [role=row], [role=listitem], article';
        const row = node.closest(rowSelector) || anchorOf(node).closest(rowSelector);
        if (!row || row === node) return null;
        let text = boundedText(row, false, false, choiceLists);
        if (ownText) text = text.replace(ownText, ' ');
        // Cut to its length with every string the report holds (`final`).
        return squeeze(text) || null;
      };

      // Visible headings in document order; candidates are visited in
      // document order too, so one pointer walks both lists once.
      const headingNodes = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
      const headings = [];
      for (let i = 0; i < headingNodes.length && i < MAX_HEADINGS && !late(); i++) {
        if (!inWriting(headingNodes[i]) && visible(headingNodes[i])) headings.push(headingNodes[i]);
      }
      let headingIndex = -1;
      const headingBefore = (node) => {
        while (headingIndex + 1 < headings.length &&
               (headings[headingIndex + 1].compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING)) {
          headingIndex += 1;
        }
        return headingIndex >= 0 ? (boundedText(headings[headingIndex]) || null) : null;
      };

      const tagRegion = { nav: 'nav', main: 'main', header: 'header', footer: 'footer', aside: 'aside' };
      const roleRegion = { navigation: 'nav', main: 'main', banner: 'header', contentinfo: 'footer', complementary: 'aside' };
      // A GET form's own query as a browser writes it, for a field of it
      // (ITER-076 stage 3, D4): its hidden fields as they are, read through
      // the input's own getter — for this alone, reported nowhere else — and
      // the field's own place, with no value. Null for a field of no GET form,
      // with no name, of a form too big to read whole, or of one that holds a
      // secret field, empty or not: D4 opens no form that holds one, as it
      // opened none before an empty one stopped walling the rest of its form
      // (2026-10-21).
      const formEntriesOf = (node) => {
        const form = node.form instanceof HTMLFormElement ? node.form : null;
        const name = attributeOf.call(node, 'name');
        if (!form || !name || String(formMethodOf(form) || 'get').toLowerCase() !== 'get') return null;
        const controls = formElementsOf(form);
        if (controls.length > 200 || formCensus(form).holds) return null;
        const entries = [];
        for (let i = 0; i < controls.length; i++) {
          const control = controls[i];
          if (control === node) {
            entries.push({ name: String(name).slice(0, MAX_URL), value: null });
            continue;
          }
          if (!(control instanceof HTMLInputElement) || String(control.type).toLowerCase() !== 'hidden' ||
              control.disabled) continue;
          const hidden = attributeOf.call(control, 'name');
          if (!hidden) continue;
          const value = String(inputValue.call(control));
          if (hidden.length > MAX_URL || value.length > MAX_URL) return null;
          entries.push({ name: String(hidden), value });
        }
        return entries;
      };
      // Whether a field sits in the page's search landmark: `role=search`, or
      // `<search>` (ITER-076 stage 3, D4).
      const inSearchOf = (node) => !!node.closest('[role~="search"], search');
      // A cookie bar drawn with no dialog role (2026-10-19: a site's bar fixed
      // to the bottom of the viewport, its consent links in it, asked a Yes on
      // every brain): the outermost box fixed to the viewport whose words
      // mention cookies is a dialog root too — its controls in the dialog
      // region, with its words — so the rules read it as the page's cookie
      // window. A sticky box is the page's own flow — a header that stays
      // at the top — not a window over it; a landmark — a nav, a footer — is
      // never the root; the walk goes on above it.
      const cookieWord = \#(jsString(CookieBanner.word)).toLowerCase();
      const landmarkTags = ['NAV', 'MAIN', 'HEADER', 'FOOTER', 'ASIDE'];
      const landmarkRoles = ['navigation', 'main', 'banner', 'contentinfo', 'complementary'];
      const cookieOverlays = new Map();
      const isCookieOverlay = (box) => {
        if (!cookieOverlays.has(box)) {
          cookieOverlays.set(box, squeeze(boundedText(box)).toLowerCase().includes(cookieWord));
        }
        return cookieOverlays.get(box);
      };
      const cookieOverlayOf = (node) => {
        let outermost = null;
        for (let box = node.parentElement; box && box !== document.body && box !== document.documentElement;
             box = box.parentElement) {
          if (landmarkTags.includes(box.tagName) || landmarkRoles.includes((box.getAttribute('role') || '').toLowerCase())) continue;
          if (getComputedStyle(box).position === 'fixed') outermost = box;
        }
        return outermost && isCookieOverlay(outermost) ? outermost : null;
      };
      const dialogSelector = 'dialog, [role=dialog], [role=alertdialog], [aria-modal=true]';
      const dialogRootOf = (node) => node.closest(dialogSelector) || cookieOverlayOf(node);
      // Whether the dialog a control sits in blocks the page: a dialog drawn
      // as one does; a cookie bar fixed to the viewport is read past.
      const dialogBlocksOf = (node) => (node.closest(dialogSelector) ? true : (cookieOverlayOf(node) ? false : null));
      // A dialog's own words, as a person reads them — the text of its root,
      // read once a look — for each control in it: what tells a cookie
      // window (ITER-076 stage 3).
      const dialogWords = new Map();
      const dialogTextOf = (node) => {
        const root = dialogRootOf(node);
        if (!root) return null;
        if (!dialogWords.has(root)) dialogWords.set(root, squeeze(boundedText(root)) || null);
        return dialogWords.get(root);
      };
      const regionOf = (node) => {
        if (dialogRootOf(node)) return 'dialog';
        const landmark = node.closest('nav, main, header, footer, aside, [role=navigation], [role=main], ' +
          '[role=banner], [role=contentinfo], [role=complementary]');
        if (!landmark) return 'other';
        const role = (landmark.getAttribute('role') || '').toLowerCase();
        return roleRegion[role] || tagRegion[landmark.tagName.toLowerCase()] || 'other';
      };

      // On screen means a person can see it now: inside the viewport and the
      // topmost thing at its centre is it or part of it on the tree a person
      // sees — a picture a slot puts in it too — not covered by an overlay,
      // not clipped away by a scrolling box. See the known limit above.
      const partOf = (hit, node) => {
        for (let current = hit, hops = 0; current && hops < 50; current = composedParent(current), hops++) {
          if (current === node) return true;
        }
        return false;
      };
      const onScreen = (node) => {
        const rect = node.getBoundingClientRect();
        if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= window.innerHeight || rect.left >= window.innerWidth) {
          return false;
        }
        const x = Math.min(Math.max(rect.left + rect.width / 2, 0), window.innerWidth - 1);
        const y = Math.min(Math.max(rect.top + rect.height / 2, 0), window.innerHeight - 1);
        const root = node.getRootNode();
        const hitRoot = root instanceof ShadowRoot && typeof root.elementFromPoint === 'function' ? root : document;
        const hit = hitRoot.elementFromPoint(x, y);
        return !!hit && (hit === node || node.contains(hit) || partOf(hit, node));
      };

      // Candidates in document order, open shadow roots walked where their
      // host stands.
      let truncated = false;
      const found = [];
      // Frames and forms met on the way, for the census of secret fields. A
      // frame is an iframe's or a frame's, or an object's that holds a
      // document of its own (Claude review c8, #7).
      const holdsAFrame = (el) => el.localName === 'iframe' || el.localName === 'frame' ||
        (el.localName === 'object' && !!el.contentWindow);
      const pageFrames = [];
      const pageForms = [];
      const walk = (root) => {
        const all = root.querySelectorAll('*');
        for (let i = 0; i < all.length; i++) {
          if (found.length >= MAX_NODES || late()) { truncated = true; return; }
          const el = all[i];
          if (el.matches(selector) || sourceOf(el) !== el) found.push(el);
          if (holdsAFrame(el)) pageFrames.push(el);
          if (el.localName === 'form') pageForms.push(el);
          if (el.shadowRoot) {
            quiet.track(el.shadowRoot);
            walk(el.shadowRoot);
            if (truncated) return;
          }
        }
      };
      walk(document);
      // Whether the walk met every control of the page: only then is a box
      // known to hold no field but one (`fieldsDrawnIn`).
      const walkedWhole = !truncated;

      const fieldTags = ['input', 'select', 'textarea'];
      // A checkbox or radio holds no typed text, so no secret: its words never
      // make it a secret field, nor its page one that asks for a secret
      // (review of I-08, F4).
      const holdsText = (el) => !nativeChoice(el);
      const autocompleteTokens = (node) =>
        (node.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter(Boolean);
      // The text nodes under a node, in order, reaching each node's children
      // through `childrenOf` — read whole, without recursion. Null when the
      // time budget runs out.
      const textNodes = (root, childrenOf) => {
        const parts = [];
        const stack = [root];
        while (stack.length > 0) {
          if (late()) return null;
          const node = stack.pop();
          if (node.nodeType === 3) {
            parts.push(node.nodeValue);
            continue;
          }
          const children = childrenOf(node);
          for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
        return parts;
      };
      // Elements whose text is no word about a field: code the page never
      // draws as text, and a control's own contents — a select's options,
      // what someone typed in a textarea.
      const wordless = ['script', 'style', 'noscript', 'template', 'select', 'textarea'];
      const isWordless = (node) => node.nodeType === 1 && wordless.includes(node.localName);
      // A node's children as the page draws them: a shadow host shows its
      // shadow root, which reaches the host's own children through slots, and
      // a slot shows the nodes assigned to it or, with none, its fallback.
      const drawnChildren = (node) => {
        if (isWordless(node)) return [];
        if (node.shadowRoot) return [node.shadowRoot];
        const assigned = node.localName === 'slot' && typeof node.assignedNodes === 'function'
          ? node.assignedNodes({ flatten: true }) : [];
        return assigned.length > 0 ? assigned : (node.childNodes || []);
      };
      // A run of breaks and seams is one break when it holds a space, else one
      // seam: "MM / YY" reads "MM YY" however its tags fall.
      const breakRun = new RegExp('[ ' + SEAM + ']+', 'gu');
      // The text of each tree under a node as its markup holds it — the
      // node's own tree, every shadow root in it and every node a slot in it
      // shows, nested ones included — each read on its own, so a word no slot
      // shows still counts and a component's drawing never breaks the words
      // around it. A text alternative (`aria-label`, `alt`, `title`) is a
      // reading of its own, as a screen reader names the element. Null when
      // the time budget runs out.
      const heldText = (root) => {
        const readings = [];
        const trees = [root];
        // A shadow root, or a node a slot shows, met on the way is left for a
        // reading of its own.
        const ownChildren = (node) => {
          if (isWordless(node)) return [];
          if (node.nodeType === 1) {
            for (const name of ['aria-label', 'alt', 'title']) {
              const value = node.getAttribute(name);
              if (value) readings.push(value);
            }
            if (node.localName === 'slot' && typeof node.assignedNodes === 'function') {
              for (const shown of node.assignedNodes({ flatten: true })) trees.push(shown);
            }
          }
          if (node.shadowRoot) trees.push(node.shadowRoot);
          return Array.from(node.childNodes || []);
        };
        while (trees.length > 0) {
          const parts = textNodes(trees.shift(), ownChildren);
          if (parts === null) return null;
          readings.push(parts.join(SEAM));
        }
        return readings.join(' ');
      };
      // All the text a label holds, as the page draws it and as its markup
      // holds it, every seam marked, the readings kept apart by a space. Null
      // when the time budget runs out.
      const composedText = (root) => {
        const drawn = textNodes(root, drawnChildren);
        if (drawn === null) return null;
        const held = heldText(root);
        if (held === null) return null;
        return drawn.join(SEAM) + ' ' + held;
      };

      // Past this many characters — counted as the page wrote them, before
      // "#" is read as "number" — a field's words are not read, as when the
      // time budget runs out: the field gives no sign-in or payment evidence
      // (`namesSignInOrPayment`), so no page can make the matching below run
      // long.
      const WORDS_LIMIT = 100000;
      // Every word that could name a field, shown or hidden and read whole:
      // a word past a display cut-off, split across tags, or drawn in a
      // component's shadow root would pass as safe. Only the time budget
      // and `WORDS_LIMIT` bound the reading; null means one ran out: the field
      // gives no evidence. Every run of anything but letters and digits becomes
      // one space, so "Verification⏎   code" and "card_number" read as the
      // words they are — except a run of invisible format characters (a soft
      // hyphen, a zero-width space), which the page may draw as nothing or as
      // a break: it becomes a seam. A run of both is then one break or one
      // seam (`breakRun`).
      // `labels`: what names it beside its own words — its own labels, or,
      // for a frame, the label it stands in too. `ownWords`: whether its own
      // name, id, placeholder, `aria-label` and title are read too.
      const fieldWords = (node, labels = labelsByReference(node).concat(node.labels ? Array.from(node.labels) : []),
                          ownWords = true) => {
        const words = ownWords ? [node.getAttribute('name'), node.id, node.getAttribute('placeholder'),
          node.getAttribute('aria-label'), node.getAttribute('title')] : [];
        for (const label of labels) {
          const text = composedText(label);
          if (text === null) return null;
          words.push(text);
        }
        const joined = words.join(' ');
        if (joined.length > WORDS_LIMIT) return null;
        // "#" reads as the word it stands for: "Card #" names a card number.
        return joined.replace(/#/g, ' number ').replace(/[^\p{L}\p{N}\p{Cf}]+/gu, ' ')
          .replace(/\p{Cf}+/gu, SEAM).replace(breakRun, (run) => (run.includes(' ') ? ' ' : SEAM));
      };
      // Words that name a payment wherever they stand, as `passwordPhrases`
      // do.
      const paymentPhrases = /(card.?number|cc.?num|credit.?card|security.?code|expir(y|ation)|valid.?(thru|through|until))/i;
      const paymentShortWords = standingAlone(['cvv', 'cvc', 'csc', 'cvv2', 'cvc2', 'mmyy', 'mm yy', 'mmyyyy',
        'mm yyyy']);
      // Words that name a secret wherever they start, but only where a word
      // ends — "card no" in "debitCardNo" or before a seam, never in "card
      // note". The end is a space, the edge or a seam; a seam inside is read
      // as nothing.
      const endingAWord = (list) => new RegExp('(?:' + list.map((word) => Array.from(word).join(SEAM + '?')).join('|') +
        ')(?=$|[ ' + SEAM + '])', 'iu');
      const paymentWordEnds = endingAWord(['card no', 'cardno']);
      // The words read run together: every seam read as nothing.
      const runTogether = (words) => words.split(SEAM).join('').replace(/ {2,}/g, ' ');
      const passwordTokens = ['current-password', 'new-password', 'one-time-code'];
      // A field that draws what it holds as dots is a password field, in any
      // language, whatever its type says (review of A3, round 1).
      const masksItsText = (node) => {
        const security = styleOf(node).webkitTextSecurity;
        return typeof security === 'string' && security !== '' && security !== 'none';
      };
      const asksForPassword = (node) => (node.type || '').toLowerCase() === 'password' ||
        autocompleteTokens(node).some((token) => passwordTokens.includes(token)) || masksItsText(node);
      const asksForCard = (node) => autocompleteTokens(node).some((token) => token.startsWith('cc-'));
      // The one place where a field is decided secret (owner decision of
      // 2026-10-03): by its structure only — a password, a one-time code, a
      // field that draws dots, card details. Its kind: a card's, which makes
      // its form a card form, or a password's. Its words never decide it.
      const markedSecret = (node) => asksForCard(node) || asksForPassword(node);
      const markedKind = (node) => (asksForCard(node) ? 'card' : asksForPassword(node) ? 'password' : null);
      // Words that name a sign-in field — a secret code's phrase does:
      // "Backup code" does, "Postal code" does not (ITER-076 I-09, review
      // round 4, decision 2) — and words that name a payment's: what the
      // agent leaves to the user, never what is kept from Jev.
      const isPasswordField = (words) => passwordPhrases.test(runTogether(words)) ||
        codePhrases.test(runTogether(words)) || passwordShortWords.test(words);
      const isPaymentField = (words) => paymentPhrases.test(runTogether(words)) || paymentShortWords.test(words) ||
        paymentWordEnds.test(words);
      // What a field's words say it asks for: a sign-in, a payment, or
      // nothing — null. A field whose words cannot be read says nothing: it
      // gives no evidence of either (owner decision of 2026-10-03).
      const askedByWords = new Map();
      const namesSignInOrPayment = (el) => {
        if (askedByWords.has(el)) return askedByWords.get(el);
        let answer = null;
        const words = isField(el) ? fieldWords(el) : null;
        if (words !== null) {
          const password = isPasswordField(words), payment = isPaymentField(words);
          if (password || payment) answer = { password, payment };
        }
        askedByWords.set(el, answer);
        return answer;
      };
      // What an ordinary field holds, as a person sees it — a text field's
      // value, a select's chosen option, an editable region's words — read
      // through the elements' own getters, then cut to a report's length.
      // Null for anything that holds no value of its own: a password, and a
      // hidden input, which a person never sees and is never read as a value
      // (owner decision of 2026-10-03) — only into its GET form's own query,
      // which builds that form's search address alone (`formEntriesOf`).
      const valueGetter = (proto) => {
        const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
        return descriptor && descriptor.get;
      };
      const inputValue = valueGetter(HTMLInputElement.prototype);
      const areaValue = valueGetter(HTMLTextAreaElement.prototype);
      const valueless = ['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file', 'hidden', 'password'];
      const rawValueOf = (node) => {
        const read = (value) => String(value == null ? '' : value);
        const tag = node.localName;
        if (tag === 'select') {
          const option = node.selectedIndex >= 0 ? node.options[node.selectedIndex] : null;
          return read(option ? option.text : '');
        }
        if (tag === 'input') {
          const type = (node.type || 'text').toLowerCase();
          return valueless.includes(type) ? null : read(inputValue.call(node));
        }
        if (tag === 'textarea') return read(areaValue.call(node));
        if (node.isContentEditable === true) return read(node.innerText);
        return null;
      };
      // Each reported field's value, read once: a page cannot show one check
      // one value and the report another.
      const values = new Map();
      // What a list sends: its chosen option's value — the words it shows
      // are another thing — and nothing when none is chosen (review round 1,
      // C5).
      const sentOfList = (node) => {
        const option = node.selectedIndex >= 0 ? node.options[node.selectedIndex] : null;
        return option ? String(option.value) : '';
      };

      // The form's own getters, not `form.action`: a control named "action"
      // would stand in for the property and lie about the destination.
      const formProperty = (name) => {
        const descriptor = Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, name);
        return (form) => descriptor.get.call(form);
      };
      const formActionOf = formProperty('action');
      const formMethodOf = formProperty('method');
      const formElementsOf = formProperty('elements');
      const attributeOf = Element.prototype.getAttribute;
      // The form around a node that is no form control itself, such as a div
      // with role=button: a script can send it (ITER-076 2.1). The page's own
      // `closest('form')` first, as its scripts would find it, then across
      // shadow roots.
      const enclosingForm = (node) => {
        const light = typeof node.closest === 'function' ? node.closest('form') : null;
        if (light instanceof HTMLFormElement) return light;
        for (let current = composedParent(node); current; current = composedParent(current)) {
          if (current instanceof HTMLFormElement) return current;
        }
        return null;
      };
      // The form a field goes with, on the tree a person sees: its own (by a
      // `form` attribute too), or the one around it — a field in a
      // component's shadow root goes with the form around the component
      // (review of A3, round 1).
      const ownerForm = (node) => (node.form instanceof HTMLFormElement ? node.form : enclosingForm(node));

      // Owner decision 4: a field once seen to be secret stays secret for the
      // life of the document — a "show password" toggle, or a framework
      // drawing the field anew under the same name, makes it no ordinary
      // field (review of A3, round 1). What is kept is the field's kind —
      // card or password, or a card's shown (`SHOWN_CARD`) — so a remembered
      // card still makes its form a card form (review of A3d, round 2,
      // N-P1-1), and a
      // name counts only in its own form: where the form stands in the tree a
      // person sees, and where it sends (N-P2-2). Kept in the world the
      // script runs in; a new document starts empty.
      // Beside it, each form's own names (N3-P1-2: a form that moves keeps
      // them), and a private key for every element the walk reports or
      // withholds, the same for the document's life: what the hands tell a
      // target by when the page redraws its role and its name (N3-P2-2).
      const memory = (() => {
        const key = '__metawhispSecretFields';
        // `frames`: each frame in no form a person saw holding a secret, and its kind, card or password (Codex
        // review of 2026-10-18, P1-1).
        // `document`: this document's own id, so a key is compared only within the document that gave it (2026-10-21).
        const documentID = () => {
          try { if (crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID(); } catch (error) {}
          return String(Date.now()) + '-' + String(Math.random()).slice(2);
        };
        const empty = () => ({ nodes: new WeakMap(), forms: new WeakMap(), names: new Map(),
                               frameNames: new WeakMap(), keys: new WeakMap(), frames: new WeakMap(), nextKey: 1,
                               document: documentID() });
        try {
          const known = window[key];
          if (!known || !(known.nodes instanceof WeakMap) || !(known.forms instanceof WeakMap) ||
              !(known.names instanceof Map) || !(known.frameNames instanceof WeakMap) ||
              !(known.keys instanceof WeakMap) || !(known.frames instanceof WeakMap)) {
            Object.defineProperty(window, key, { value: empty(), configurable: true });
          }
          // A memory kept from before the document had an id gets one, and keeps all it knows.
          if (typeof window[key].document !== 'string') window[key].document = documentID();
          return window[key];
        } catch (error) {
          return empty();
        }
      })();
      const keyOf = (node) => {
        let known = memory.keys.get(node);
        if (known === undefined) {
          known = memory.nextKey++;
          memory.keys.set(node, known);
        }
        return known;
      };
      // Where an element stands in the tree a person sees: each step up, its
      // tag and its place among its parent's children, a shadow root's top
      // counted under its host. A form drawn anew in its place keeps it.
      const placeOf = (el) => {
        const steps = [];
        for (let current = el, hops = 0; current && hops < 64; hops++) {
          const parent = current.parentNode;
          if (!parent) break;
          const index = parent.children ? Array.prototype.indexOf.call(parent.children, current) : -1;
          steps.push(current.localName + ':' + index);
          current = parent instanceof ShadowRoot ? parent.host : (parent.nodeType === 1 ? parent : null);
        }
        return steps.join('/');
      };
      const nameOfField = (node) => attributeOf.call(node, 'name') || attributeOf.call(node, 'id') || '';
      // The names a document's fields had: the page's own, or — a frame's
      // fields remembered apart (N3-P1-3) — those of the frame's document,
      // kept with that document: a new document in the same frame starts
      // with none (review of I-02, N4-P2-1).
      const namesOf = (node) => {
        const doc = node.ownerDocument;
        if (!doc || doc === document) return memory.names;
        let names = memory.frameNames.get(doc);
        if (!names) {
          names = new Map();
          memory.frameNames.set(doc, names);
        }
        return names;
      };
      // Where a name counts when the form itself was drawn anew: the form's
      // place and destination; with no form, the document.
      const signatureOf = (node, form) => (form ? placeOf(form) + '\u001F' + String(formActionOf(form)) : '') +
        '\u001F' + nameOfField(node);
      // A field the page marks secret by none of its structure that is a
      // card's — by its words or what it holds — is remembered as a card's
      // shown: its form a card form, what it holds reported. A card stays a
      // card, and a secret field's kind is never lost to a shown card.
      const SHOWN_CARD = 'shown card';
      const lastingKind = (known, kind) => (known === 'card' ? 'card'
        : kind === SHOWN_CARD && known !== undefined ? known : kind);
      const rememberedKind = (node) => {
        const known = memory.nodes.get(node);
        if (known !== undefined) return known;
        const name = nameOfField(node);
        if (!name) return undefined;
        const form = ownerForm(node);
        // The same form, wherever it moved.
        const own = form ? memory.forms.get(form) : undefined;
        if (own && own.has(name)) return own.get(name);
        // Its place: only for a form drawn anew there, never for one that took
        // the place of a form still on the page.
        const placed = namesOf(node).get(signatureOf(node, form));
        if (!placed) return undefined;
        const first = placed.form && typeof placed.form.deref === 'function' ? placed.form.deref() : null;
        if (form && first && first !== form && first.isConnected) return undefined;
        return placed.kind;
      };
      // A card stays a card: its kind is the one that makes a form a card form.
      const remember = (node, kind) => {
        const lasting = lastingKind(memory.nodes.get(node), kind);
        memory.nodes.set(node, lasting);
        const name = nameOfField(node);
        if (!name) return;
        const form = ownerForm(node);
        if (form) {
          if (!memory.forms.has(form)) memory.forms.set(form, new Map());
          const own = memory.forms.get(form);
          own.set(name, lastingKind(own.get(name), lasting));
        }
        const names = namesOf(node);
        const signature = signatureOf(node, form);
        const placed = names.get(signature);
        names.set(signature, {
          kind: lastingKind(placed && placed.kind, lasting),
          form: form && typeof WeakRef === 'function' ? new WeakRef(form) : null
        });
      };
      // An editable region with a secret field drawn inside it — a password
      // widget in a message editor — is secret itself: its words include the
      // widget's (review of A3, round 1). Past the walk's bound it counts as
      // holding one.
      const holdsSecretWidget = (node) => {
        if (node.isContentEditable !== true && !writingRoles.includes(firstKnownRole(node))) return false;
        const stack = Array.from(drawnChildren(node));
        for (let walked = 0; stack.length > 0; walked++) {
          if (walked >= MAX_WALK || late()) return true;
          const current = stack.pop();
          if (current.nodeType === 11) { stack.push(...Array.from(current.childNodes)); continue; }
          if (current.nodeType !== 1) continue;
          if (markedSecret(current)) return true;
          stack.push(...Array.from(drawnChildren(current)));
        }
        return false;
      };

      // First pass: what a person can see, and which of it is sensitive.
      const seen = [];
      // Whether a control the walk reports sits around an element.
      const insideAControl = (el) => {
        for (let current = composedParent(el), hops = 0; current && hops < 50; current = composedParent(current), hops++) {
          if (current.matches(selector)) return true;
        }
        return false;
      };
      for (const node of found) {
        if (late()) { truncated = true; break; }
        if (insideWriting(node) || insideSensitiveField(node) || !visible(node)) continue;
        // A label stands for its checkbox or radio only where the input cannot
        // be seen itself, never for one switched off, and as the first of its
        // labels a person sees (ITER-076 I-08, a reference browser agent's
        // walk) — and never where it or the input sits inside a control of its
        // own, which is that control already (review of I-08, F2).
        const source = sourceOf(node);
        if (source !== node && (visible(source) || source.matches(':disabled') ||
            source.closest('[aria-disabled="true"],[inert]') ||
            Array.from(source.labels || []).find((label) => visible(label)) !== node ||
            insideAControl(node) || insideAControl(source))) continue;
        seen.push(node);
      }
      let loginForm = false, paymentForm = false;
      // The fields that are a card's — by their words, their autocomplete or
      // what they hold: their forms take a payment.
      const cardFields = new Set();
      // Each sensitive field's kind, remembered for the document's life.
      const kinds = new Map();
      const secret = (node, kind) => { sensitive.add(node); kinds.set(node, kind); };
      // The fields whose words name a sign-in or a payment, which the page
      // does not mark secret: what they hold is reported, and their forms are
      // the user's to send (owner decision of 2026-10-03).
      const namedFields = [];
      for (const node of seen) {
        if (!isField(node)) continue;
        const known = rememberedKind(node);
        const marked = known !== undefined && known !== SHOWN_CARD ? known
          : markedKind(node) || (holdsSecretWidget(node) ? 'password' : null);
        // A field the page marks secret is a card's by its words, as any
        // field is, or as a card it showed: payment before password (Claude
        // review c11, #3). What it holds stays unread.
        const kind = marked === 'password' && (known === SHOWN_CARD || (namesSignInOrPayment(node) || {}).payment)
          ? 'card' : marked;
        if (kind !== null) {
          secret(node, kind);
          if (kind === 'card') { paymentForm = true; cardFields.add(node); }
          if (kind === 'password') loginForm = true;
          continue;
        }
        const named = namesSignInOrPayment(node);
        if (named !== null) {
          namedFields.push(node);
          if (named.password) loginForm = true;
          if (named.payment) { paymentForm = true; cardFields.add(node); }
        }
        const raw = rawValueOf(node);
        if (raw !== null) values.set(node, raw);
        if (known === SHOWN_CARD || (raw !== null && holdsCardNumber(normalizeSecrets(raw)))) cardFields.add(node);
      }
      // A card number split over fields of one form ("4111" "1111" "1111"
      // "1111") is one card, whatever words the page gives them, in any
      // language (review of A3, round 1): its form takes a payment. What the
      // fields hold is shown as a person sees it (owner decision of
      // 2026-10-03).
      const digitsOnly = (raw) => {
        const digits = normalizeSecrets(raw).replace(/[\s._\/-]/g, '');
        return /^\d+$/.test(digits) ? digits : null;
      };
      const fieldsByForm = new Map();
      for (const node of values.keys()) {
        const form = ownerForm(node);
        if (!form) continue;
        if (!fieldsByForm.has(form)) fieldsByForm.set(form, []);
        fieldsByForm.get(form).push(node);
      }
      for (const fields of fieldsByForm.values()) {
        for (let start = 0; start < fields.length; start++) {
          let digits = '';
          for (let end = start; end < fields.length && end < start + 6; end++) {
            const part = digitsOnly(values.get(fields[end]) ?? '');
            if (part === null || part.length < 2 || part.length > 6) break;
            digits += part;
            if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) {
              for (let i = start; i <= end; i++) cardFields.add(fields[i]);
              break;
            }
          }
        }
      }
      // Any card field makes the page take a payment, in a form or not.
      if (cardFields.size > 0) paymentForm = true;
      // A field once a card's stays one for the document's life, shown as it
      // is: a card number the page masks once typed keeps its form a card
      // form (review of A3d, round 2, N-P1-1).
      for (const node of cardFields) if (!sensitive.has(node)) remember(node, SHOWN_CARD);
      // A cheap look over the light document — not shadow roots, not frames —
      // past the scan's cut-off, at its first 50 matches, so a password below
      // the cut-off still flags the page.
      const obvious = document.querySelectorAll('input[type=password], input[autocomplete~="one-time-code"], ' +
        'input[autocomplete~="current-password"], input[autocomplete~="new-password"], ' +
        'input[autocomplete*="cc-"], select[autocomplete*="cc-"]');
      const obviouslySecret = [];
      for (let i = 0; i < obvious.length && i < 50; i++) {
        const field = obvious[i];
        if (!visible(field)) continue;
        obviouslySecret.push(field);
        if (asksForPassword(field)) {
          loginForm = true;
        } else {
          paymentForm = true;
        }
      }
      for (const node of sensitive) remember(node, kinds.get(node) || 'secret');

      // Whether a secret field holds anything: a value — or, for a password
      // the browser filled in, which the page's scripts read as empty until
      // the user acts, Chrome's `:autofill` (review of A3d, round 2, N-P1-2).
      const autofilled = (node) => [':autofill', ':-webkit-autofill'].some((state) => {
        try { return node.matches(state); } catch (error) { return false; }
      });
      const isFilled = (node) => {
        if (autofilled(node)) return true;
        const tag = node.localName;
        if (tag === 'input') {
          const type = (node.type || 'text').toLowerCase();
          if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image'].includes(type)) return false;
          return String(inputValue.call(node)) !== '';
        }
        if (tag === 'textarea') return String(areaValue.call(node)) !== '';
        if (tag === 'select') {
          const option = node.selectedIndex >= 0 ? node.options[node.selectedIndex] : null;
          return !!option && String(option.value) !== '';
        }
        return squeeze(node.isContentEditable === true ? node.innerText : node.textContent) !== '';
      };
      // A secret field its form needs, empty (2026-10-21): one the page marks
      // secret by its structure, or remembers so, that holds nothing, and that
      // is `required` or `aria-required`, or whose autocomplete names it the
      // sign-in's own password, a new one or a code (`passwordTokens`). Such a
      // form sends no secret, but a press that sends it is the user's
      // sign-in. `required` and `aria-required` are read through the
      // element's own getter.
      const needsSecret = (node) => (sensitive.has(node) || sensitiveField(node)) && !isFilled(node) &&
        ((fieldTags.includes(node.localName) && attributeOf.call(node, 'required') !== null) ||
         attributeOf.call(node, 'aria-required') === 'true' ||
         autocompleteTokens(node).some((token) => passwordTokens.includes(token)));

      // Frames (review of A3d, round 2, P1-5): one of the page's own origin is
      // read for secret fields — its shadow roots and its own frames too; one
      // of another origin cannot be read: what it holds is unknown. Too much
      // to read, or no time left, is unknown as well.
      const MAX_FRAMES = 50, MAX_FRAME_ELEMENTS = 5000, MAX_FRAME_DEPTH = 3;
      // A frame's field by its structure (`markedKind`), or by the words
      // that name a payment's or a sign-in's field (`payment`, `signIn`):
      // what its frame asks for, never what is kept from Jev.
      const frameKind = (el) => {
        if (!holdsText(el) || (!fieldTags.includes(el.localName) && !fieldRoles.includes(roleOf(el)))) return null;
        const marked = markedKind(el);
        if (marked !== null) return marked;
        if (holdsSecretWidget(el)) return 'password';
        const named = namesSignInOrPayment(el);
        return named === null ? null : named.payment ? 'payment' : 'signIn';
      };
      const frameCensuses = new Map();
      const frameCensus = (frame, depth) => {
        if (frameCensuses.has(frame)) return frameCensuses.get(frame);
        const census = { secret: false, filled: false, unknown: false, password: false, card: false, fields: false };
        frameCensuses.set(frame, census);
        let doc = null;
        try { doc = frame.contentDocument || null; } catch (error) { doc = null; }
        if (!doc || depth > MAX_FRAME_DEPTH) { census.unknown = true; return census; }
        const roots = [doc];
        for (let visited = 0; roots.length > 0;) {
          const all = roots.pop().querySelectorAll('*');
          for (let i = 0; i < all.length; i++) {
            if (++visited > MAX_FRAME_ELEMENTS || late()) { census.unknown = true; return census; }
            const el = all[i];
            if (el.shadowRoot) roots.push(el.shadowRoot);
            if (holdsAFrame(el)) {
              const inner = frameCensus(el, depth + 1);
              for (const key of Object.keys(census)) census[key] = census[key] || inner[key];
              continue;
            }
            if (isEntryField(el)) census.fields = true;
            // A frame's field once secret stays secret, as the page's own do.
            const known = rememberedKind(el);
            const kind = known !== undefined ? known : frameKind(el);
            if (kind === null) continue;
            if (kind !== 'payment' && kind !== 'signIn') remember(el, kind);
            census.secret = true;
            if (kind === 'card' || kind === 'payment' || kind === SHOWN_CARD) census.card = true;
            if (kind === 'password' || kind === 'signIn') census.password = true;
            if (isFilled(el)) census.filled = true;
          }
        }
        return census;
      };

      // A card's field: one the walk found a card's — by its words, its
      // structure, what it holds, or as a card it showed — or one whose
      // structure or words ask for a card. Its form takes a payment, the
      // user's part, filled or not (owner decision of 2026-10-03).
      const isCardField = (node) => cardFields.has(node) || asksForCard(node) ||
        (namesSignInOrPayment(node) || {}).payment === true;
      // Which forms hold a secret field, which of them hold one filled in,
      // which hold a card's field, which hold what cannot be known, which
      // need one they hold empty, and whether one stands outside any form: a
      // visible one the walk found or the look above saw, a hidden one the
      // walk found in a form, shadow roots included (review of A3, round 1),
      // and one in a frame (P1-5) — which no form needs: what a frame holds
      // walls its form, or does not, as it did.
      const secretForms = new Set();
      const filledForms = new Set();
      const cardForms = new Set();
      const unknownForms = new Set();
      const neededForms = new Set();
      let formlessSecret = false;
      for (const node of Array.from(sensitive).concat(obviouslySecret, namedFields, Array.from(cardFields))) {
        const form = ownerForm(node);
        if (!form) { formlessSecret = true; continue; }
        secretForms.add(form);
        if (isFilled(node)) filledForms.add(form);
        if (isCardField(node)) cardForms.add(form);
        if (needsSecret(node)) neededForms.add(form);
      }
      const seenOnes = new Set(seen);
      // The secret fields the page hides, for their forms and their lists;
      // and a hidden field whose words name a sign-in or a payment, for its
      // form.
      const hiddenSecrets = [];
      for (const node of found) {
        if (late()) break;
        if (sensitive.has(node) || seenOnes.has(node) || !isField(node)) continue;
        if (markedSecret(node)) hiddenSecrets.push(node);
        else if (namesSignInOrPayment(node) === null) continue;
        const form = ownerForm(node);
        if (!form) continue;
        secretForms.add(form);
        if (isFilled(node)) filledForms.add(form);
        if (isCardField(node)) cardForms.add(form);
        if (needsSecret(node)) neededForms.add(form);
      }
      const allFrames = new Set(pageFrames);
      const lightFrames = document.querySelectorAll('iframe, frame, object');
      for (let i = 0; i < lightFrames.length; i++) if (holdsAFrame(lightFrames[i])) allFrames.add(lightFrames[i]);
      // What the page names a frame by, as a field is named: the label it
      // stands in, the words `aria-labelledby` names — whatever its own
      // words say (Claude review of I-09, kept 12); its own words — name,
      // id, title, `aria-label` — only where it holds a field (Claude review
      // c8, #6), or may: a frame of another origin cannot be read (Claude
      // review c11, #4). They say what the frame asks for — a sign-in or a
      // payment, the user's part, which walls a frame of another site for
      // acting (`namedFrames`) — and never hide it: a person sees what it
      // holds, and its own look withholds its fields the page marks secret
      // by structure (owner decision of 2026-10-03). Each kind: 'card',
      // 'password', or null — also when the words could not be read.
      const labelAround = (el) => {
        for (let current = composedParent(el); current; current = composedParent(current)) {
          if (current instanceof HTMLLabelElement) return current;
        }
        return null;
      };
      const kindByWords = (words) => words === null ? null : isPaymentField(words) ? 'card'
        : isPasswordField(words) ? 'password' : null;
      const ownerKinds = new Map();
      const ownerKind = (owner) => {
        if (ownerKinds.has(owner)) return ownerKinds.get(owner);
        const around = labelAround(owner);
        const labels = labelsByReference(owner).concat(around ? [around] : []);
        const kind = { labelled: labels.length > 0 ? kindByWords(fieldWords(owner, labels, false)) : null,
                       titled: kindByWords(fieldWords(owner, [], true)) };
        ownerKinds.set(owner, kind);
        return kind;
      };
      // Each frame's census, and the kind of field the page names it as, if
      // any: labelled, or titled and holding a field — or one not known.
      const censusOf = new Map();
      const namedKind = (owner) => {
        const named = ownerKind(owner);
        const census = censusOf.get(owner) || {};
        return named.labelled || (named.titled && (census.fields || census.unknown) ? named.titled : null);
      };
      // What the page names a frame it shows as: the app reads it as every
      // frame of another site's, for acting (`ObservedPage.merging`).
      const namedFrames = { loginForm: false, paymentForm: false };
      let framesRead = 0;
      for (const frame of allFrames) {
        const census = framesRead++ < MAX_FRAMES && !late() ? frameCensus(frame, 0) : { unknown: true };
        censusOf.set(frame, census);
        const named = namedKind(frame);
        if (named !== null && visible(frame)) namedFrames[named === 'card' ? 'paymentForm' : 'loginForm'] = true;
        const form = enclosingForm(frame);
        // A frame no one sees holds nothing typed into it (2026-10-16) — unless it holds a secret filled in, or a
        // person saw it holding one: a card typed, then its frame hidden as a checkout moves on, goes with the
        // page's next press (Codex review of 2026-10-18, P1-1). A frame once seen so stays one, of its kind, for
        // the document's life, as a field once secret does — whatever it is named or holds by then (Codex
        // re-review of 2026-10-18, P1: hidden and its title taken away, it was none). A card stays a card.
        const shownOrTyped = visible(frame) || census.filled;
        const seenAs = memory.frames.get(frame);
        const card = ((census.card || named === 'card') && shownOrTyped) || seenAs === 'card';
        const password = ((census.password || named === 'password') && shownOrTyped) || seenAs === 'password';
        if (card) paymentForm = true;
        if (password) loginForm = true;
        if (form) {
          if (census.secret || census.unknown || named !== null) secretForms.add(form);
          if (census.filled) filledForms.add(form);
          // A frame that holds a card's field, or that the page names one,
          // takes a payment. One of another origin, or not read, holds what
          // is not known — and so does one the page names a sign-in's field:
          // its own fields are read by their structure and their own words,
          // so whether the field the page names holds anything is not read.
          if (census.card || named === 'card') cardForms.add(form);
          if (census.unknown || named === 'password') unknownForms.add(form);
        } else if (card || password) {
          formlessSecret = true;
          if (visible(frame)) memory.frames.set(frame, card ? 'card' : 'password');
        }
      }
      // The lists fields own (review of I-08, F4; Codex review 1 of I-08,
      // P1-1): every list that a field, or anything inside it — reportable or
      // not, in its shadow roots too — names by `aria-controls` or
      // `aria-owns`, and every list those name in turn. One rule for a page
      // checked whole, whose seeds are its secret fields, shown or hidden, and
      // for one that is not, whose seeds are all its fields (Claude review of
      // I-08's round-2 fix). Read with the browser's own queries, so a field's
      // thousands of parts do not cut it short; past the census's count, or
      // out of time, it gives null: who owns what is unknown.
      const listsOwnedBy = (seeds) => {
        const held = new Set();
        const queue = Array.from(seeds);
        let counted = 0;
        while (queue.length > 0) {
          if (late()) return null;
          const part = queue.shift();
          const trees = part.shadowRoot ? [part, part.shadowRoot] : [part];
          const namers = [part];
          for (let t = 0; t < trees.length; t++) {
            const all = trees[t].querySelectorAll('*');
            counted += all.length;
            if (counted > MAX_CENSUS) return null;
            for (let i = 0; i < all.length; i++) {
              if (all[i].hasAttribute('aria-controls') || all[i].hasAttribute('aria-owns')) namers.push(all[i]);
              if (all[i].shadowRoot) trees.push(all[i].shadowRoot);
            }
          }
          for (const namer of namers) {
            const named = listsNamedBy(namer);
            if (named === null) return null;
            for (const list of named) {
              if (!held.has(list)) { held.add(list); queue.push(list); }
            }
          }
        }
        return held;
      };
      const secretOwned = listsOwnedBy(Array.from(sensitive).concat(hiddenSecrets));
      if (secretOwned === null) truncated = true;
      else for (const list of secretOwned) secretLists.add(list);
      // A walk cut short may not have met every field the page marks secret
      // (Codex review 3 of I-08, P1-1): each is found by the browser's own
      // queries in every open tree of the page, counted apart from the walk's
      // bound — a tree past it is still looked in — and what it names as its
      // lists is held as its own. A page with more parts than the count reads,
      // or a census out of time, leaves who owns what unknown
      // (`listsUnknown`).
      if (truncated) {
        const trees = [document];
        const marked = [];
        let counted = 0;
        let whole = true;
        for (let t = 0; t < trees.length && whole; t++) {
          const all = trees[t].querySelectorAll('*');
          counted += all.length;
          if (counted > MAX_CENSUS || late()) { whole = false; break; }
          for (let i = 0; i < all.length; i++) {
            if (all[i].shadowRoot) trees.push(all[i].shadowRoot);
            if (isField(all[i]) && markedSecret(all[i])) marked.push(all[i]);
          }
        }
        const owned = whole ? listsOwnedBy(marked) : null;
        if (owned === null) listsUnknown = true;
        else for (const list of owned) secretLists.add(list);
      }

      // The block a person sees words in: the nearest box around them that
      // is not drawn inline. Its kind, as the approval page names them.
      const blockOf = (el) => {
        let current = el;
        for (let hops = 0; current && hops < 20; hops++) {
          const display = styleOf(current).display;
          if (!display.startsWith('inline') && display !== 'contents') return current;
          current = composedParent(current);
        }
        return current;
      };
      const kindOf = (el) => {
        if (!el) return 'paragraph';
        if (/^h[1-6]$/.test(el.localName) || firstKnownRole(el) === 'heading') return 'heading';
        return el.localName === 'li' || firstKnownRole(el) === 'listitem' ? 'list_item' : 'paragraph';
      };
      // A rating drawn as stars states its value only in markup a person reads as stars (a reference browser
      // agent's `capture.js` `ratingOf`, MIT): a `star-rating` class carrying a One..Five word, or the label of a
      // widget a class or role names as one. Counting icons never works: a site colours a fixed row of them by
      // class (books.toscrape: `<p class="star-rating Five">`, five identical icons whatever the rating).
      const RATING_WORD = { one: 'One', two: 'Two', three: 'Three', four: 'Four', five: 'Five' };
      const RATING_LABEL = /\b[1-5]\s*(?:\/|out of)\s*5\b|\b[1-5]\s*stars?\b/i;
      const ratingOf = (el) => {
        const classes = Array.from(el.classList || []).map((name) => name.toLowerCase());
        if (classes.includes('star-rating')) {
          for (const token of classes) if (RATING_WORD[token]) return RATING_WORD[token] + ' stars';
        }
        if (!classes.some((name) => name.includes('star') || name.includes('rating'))
            && el.getAttribute('role') !== 'img') return '';
        const label = el.getAttribute('aria-label') || el.getAttribute('title');
        return label && RATING_LABEL.test(label) ? squeeze(label) : '';
      };

      // The page's own words for the writer (§6.6): the visible text of its
      // main content — every part the page marks main, in the page's order, a
      // part inside another once; or its body, when it marks none or they
      // hold no word a person sees (ITER-076 stage 4c: a search engine's
      // results marked three parts, the first empty) — on the tree a person
      // sees (shadow roots and what slots show included), without
      // anything someone wrote, any sensitive field's content or a custom
      // select's choice, never more than `limit` characters, as a person
      // reads them (owner decision of 2026-10-03). Asked for on its own, it
      // is all the walk returns. What the page's payment is read by too
      // (Claude review c8, #5). A read out of time keeps what it read, as one
      // out of room does — never all or nothing (ITER-076 I-10, critic 14) —
      // and either says the words were cut (`textCut`). With `lines`, the
      // reader's (ITER-076 brain, step 2): the same words, each block a person
      // sees — a heading, a list item, a paragraph, a line a break ends — on a
      // line of its own, with its kind. What the read met is kept beside it
      // (`excerptWalk`, ITER-076 stage 4a), by kinds and numbers: where it
      // began, how many places mark a main content, whether the page was
      // hidden, the words it met and kept — text nodes that hold any — the
      // rule that left each of the rest, and what cut it: a read that keeps
      // nothing says why.
      let textCut = false;
      let excerptWalk = null;
      // The frames the reader's lines were read in (2026-10-08).
      let excerptFrames = new Set();
      // `fromBody`: the body, whatever the page marks.
      const readExcerpt = (limit, lines, fromBody) => {
        const marked = document.querySelectorAll('main, [role=main]');
        const parts = fromBody ? [] : Array.from(marked).filter((part) =>
          !(part.parentElement && part.parentElement.closest('main, [role=main]')));
        const roots = parts.length > 0 ? parts : document.body ? [document.body] : [];
        const root = roots[0];
        let out = '';
        const blocks = [];
        let block = null;
        const tally = { root: !root || root === document.body ? 'body' : root.localName === 'main' ? 'main' : 'role',
                       roots: marked.length, hidden: document.hidden === true,
                       met: 0, kept: 0, dropped: {}, cut: null };
        excerptWalk = tally;
        excerptFrames = new Set();
        const stack = [];
        for (let i = roots.length - 1; i >= 0; i--) stack.push(roots[i]);
        let cut = false;
        // Words a person sees at `place`: into the excerpt and, with `lines`, into the block they stand in.
        const add = (place, text) => {
          const whole = ' ' + text;
          if (whole.length > limit - out.length) {
            cut = true;
            tally.cut = tally.cut || 'limit';
          }
          const words = whole.slice(0, limit - out.length);
          out += words;
          if (!lines) return;
          const here = blockOf(place);
          if (here !== block || blocks.length === 0) blocks.push([kindOf(here), '']);
          block = here;
          blocks[blocks.length - 1][1] += words;
        };
        for (let walked = 0; stack.length > 0; walked++) {
          if (walked >= MAX_EXCERPT_NODES || out.length >= limit || late()) {
            cut = true;
            tally.cut = walked >= MAX_EXCERPT_NODES ? 'nodes' : out.length >= limit ? 'limit' : 'time';
            break;
          }
          const node = stack.pop();
          if (node.nodeType !== 3) {
            if (node.nodeType === 1 && node.localName === 'br') block = null;
            // A frame of the page's origin is read where it stands, under the
            // headings above it, in the reader's lines (2026-10-08; a reference
            // browser agent's `capture.js`, MIT): its body is walked in its
            // place. One that cannot be read is what the count says.
            if (lines && node.nodeType === 1 && (node.localName === 'iframe' || node.localName === 'frame')) {
              let inner = null;
              try { inner = node.contentDocument; } catch (error) { inner = null; }
              if (inner && inner.body && styleOf(node).display !== 'none') {
                excerptFrames.add(node);
                block = null;
                stack.push(inner.body);
              }
              continue;
            }
            // A rating drawn as stars is read where it stands, before what it holds.
            const rating = node.nodeType === 1 ? ratingOf(node) : '';
            if (rating && !unreadableBecause(node, false) && visible(drawnBox(node))) add(node, rating);
            // Not into an element that is not drawn, nor into a drawing: an
            // icon sprite holds no words and could use up the walk.
            const skipped = node.nodeType === 1 && (node.localName === 'svg' || styleOf(node).display === 'none');
            if (!skipped && pushDrawnChildren(stack, node, MAX_EXCERPT_NODES - walked - 1)) {
              cut = true;
              tally.cut = tally.cut || 'nodes';
            }
            continue;
          }
          const place = textPlace(node);
          const left = !place ? 'noPlace'
            : unreadableBecause(place, false) || (visible(drawnBox(place)) ? null : 'unseen');
          if (/\S/.test(String(node.nodeValue))) {
            tally.met += 1;
            if (left) tally.dropped[left] = (tally.dropped[left] || 0) + 1;
            else tally.kept += 1;
          }
          if (left) continue;
          add(place, String(node.nodeValue));
        }
        if (parts.length > 0 && tally.kept === 0) return readExcerpt(limit, lines, true);
        textCut = cut;
        if (lines) return blocks.map(([kind, text]) => [kind, ownMasked(text)]).filter(([, text]) => text !== '');
        return ownMasked(out);
      };
      if (options && options.excerpt && options.alone && options.lines) {
        const blocks = readExcerpt(options.excerpt, true);
        return { blocks, url: addressMasked(location.href).slice(0, MAX_URL),
                 frames: Array.from(allFrames).filter((frame) => !excerptFrames.has(frame)).length, walk: excerptWalk };
      }
      if (options && options.excerpt && options.alone) {
        return { excerpt: readExcerpt(options.excerpt).slice(0, options.excerpt),
                 url: addressMasked(location.href).slice(0, MAX_URL), title: collapse(titleText()) };
      }

      // A button with a missing or unknown type submits; the normalised
      // `type` says so.
      const isSubmitter = (el) => (el instanceof HTMLButtonElement && el.type === 'submit') ||
        (el instanceof HTMLInputElement && (el.type === 'submit' || el.type === 'image'));
      // A submit button a person can press: enabled — not disabled, itself or
      // by its fieldset, nor inert — and drawn (`visible`): not hidden, not
      // display:none or visibility:hidden, not of zero size (ITER-076 I-09,
      // round 5; Claude review c10, #15).
      const pressable = (control) => !control.matches(':disabled') && !control.closest('[inert]') &&
        visible(control);
      // The form's first submitter that could itself be reported — one that
      // is sensitive, or sits inside someone's writing or a sensitive field,
      // never names the form — and, `pressed`, the first a person can press:
      // one no one can press still names its form, but sends nothing a change
      // sets (round 5, #15; Claude review c11, #11).
      const firstSubmitter = (form, pressed) => {
        const controls = formElementsOf(form);
        for (let i = 0; i < controls.length && i < 200; i++) {
          const control = controls[i];
          if (isSubmitter(control) && !insideWriting(control) && !insideSensitive(control) &&
              !insideChoice(control) && (!pressed || pressable(control))) return control;
        }
        return null;
      };
      // The submit button an element sits in, itself included: a span inside
      // one submits its form when clicked.
      const submitterAround = (node) => {
        for (let current = node; current; current = composedParent(current)) {
          if (isSubmitter(current)) return current;
        }
        return null;
      };
      // A form whose fields carry an OAuth request (client_id with
      // redirect_uri, response_type or request_uri), hidden ones included.
      const carriesOAuth = (form) => {
        const names = new Set();
        const controls = formElementsOf(form);
        for (let i = 0; i < controls.length && i < 200; i++) {
          const name = String(controls[i].name || '').toLowerCase();
          if (name) names.add(name);
        }
        return names.has('client_id') &&
          (names.has('redirect_uri') || names.has('response_type') || names.has('request_uri'));
      };
      // Where a form sends. A GET form with no action of its own — none, a
      // blank one, or only a fragment — sends to the page's address, with the
      // page's query replaced by its fields: the page's query is not its
      // destination, so it stays the same form when the query changes. An
      // action the page names is kept whole — a script may send it as it is.
      const destinationOfForm = (action, method, named) => {
        const address = String(action);
        const own = named === null ? '' : named.trim();
        if (method !== 'get' || (own !== '' && !own.startsWith('#'))) return address;
        // An action of only a fragment ("#") names a place on the page: the
        // form still sends to the page's address, and keeps that place.
        const cut = address.search(/[?#]/);
        const hash = address.indexOf('#');
        return (cut === -1 ? address : address.slice(0, cut)) + (own.startsWith('#') && hash !== -1 ? address.slice(hash) : '');
      };
      // The controls a click only sets, as the policy reads them
      // (`SafetyGuard.editRoles`): clicking one sends no form.
      const setsOnly = ['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio', 'option', 'tab'];
      // A form that asks for a file it does not hold yet: a required file
      // field with none picked (ITER-076 I-08).
      // A form too big to read whole counts as one that does: what is not
      // known needs the user (Codex review 1 of I-08, P2-1).
      const wantsFile = (form) => {
        const controls = formElementsOf(form);
        for (let i = 0; i < controls.length && i < 200; i++) {
          const control = controls[i];
          if (control instanceof HTMLInputElement && (control.type || '').toLowerCase() === 'file' && control.required &&
              (!control.files || control.files.length === 0)) return true;
        }
        return controls.length > 200;
      };
      // Whether a link goes to a place on its own page — the page's address
      // with a fragment: its click is the page script's to answer, a demo
      // request's window or a tab's panel (ITER-076, 2026-10-07).
      const placeOnItsPage = (node) => {
        const href = destinationOf(node);
        if (!href || !href.includes('#')) return false;
        try {
          const place = new URL(href);
          const page = new URL(location.href);
          place.hash = '';
          page.hash = '';
          return place.href === page.href;
        } catch (error) {
          return false;
        }
      };
      // A link only goes to its own address, so a form around it says nothing
      // about it — but one to a place on its own page, which is clicked as
      // every other control is.
      const formInfo = (node, role) => {
        // A label for a submit button sends that button's form.
        const labelled = node instanceof HTMLLabelElement && node.control && isSubmitter(node.control) ? node.control : null;
        const owner = labelled || (node.form instanceof HTMLFormElement ? node : submitterAround(node));
        let form = owner && owner.form instanceof HTMLFormElement ? owner.form : null;
        const around = form || (role === 'link' && !placeOnItsPage(node)) ? null : enclosingForm(node);
        form = form || around;
        if (!form) {
          return { formAction: null, formMethod: null, formSubmitLabel: null, submitUnpressable: false, submits: false,
                   formGrants: null, needsFile: false };
        }
        const own = !around && isSubmitter(owner) ? owner : null;
        const ownAction = own && own.hasAttribute('formaction');
        const action = ownAction ? own.formAction : formActionOf(form);
        const named = ownAction ? attributeOf.call(own, 'formaction') : attributeOf.call(form, 'action');
        const method = String((own && own.hasAttribute('formmethod') ? own.formMethod : formMethodOf(form)) || 'get')
          .toLowerCase();
        const submit = own || firstSubmitter(form);
        return {
          formAction: action ? String(destinationOfForm(action, method, named)).slice(0, MAX_URL) : null,
          formMethod: method,
          formSubmitLabel: submit ? (nameOf(submit, false, false) || null) : null,
          // Its submit buttons: there are some, and none a person can press.
          submitUnpressable: !!submit && !firstSubmitter(form, true),
          // Clicking it sends the form: it is, or sits in, one of its submitters.
          submits: !!own,
          formGrants: carriesOAuth(form),
          // Its click may send the form — a native submitter, whatever role
          // it names (Codex review 1 of I-08, P2-1), or anything but a control
          // a click only sets, or a field — and the form needs a file from the
          // user's disk: theirs to pick (review of I-08, F1).
          needsFile: (!!own || (!setsOnly.includes(role) && !fieldRoles.includes(role))) && wantsFile(form)
        };
      };
      const checkedOf = (node, tag, role) => {
        if (tag === 'input' && ['checkbox', 'radio'].includes((node.type || '').toLowerCase())) return !!node.checked;
        if (['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) {
          const state = node.getAttribute('aria-checked');
          return state === 'true' ? true : (state === 'false' ? false : null);
        }
        return null;
      };
      // Whether a person cannot change a box, a radio or a switch (2026-10-21): one switched off — itself or by its
      // fieldset — marked `aria-disabled` itself or around it, or inside an inert box; what tells a cookie window's
      // necessary switch. Null for any other control.
      const disabledOf = (node, role) => {
        if (!['checkbox', 'radio', 'switch', 'menuitemcheckbox', 'menuitemradio'].includes(role)) return null;
        return node.matches(':disabled') || !!node.closest('[aria-disabled="true"],[inert]');
      };
      // Whether the part of the page a control shows or hides is shown (`aria-expanded`, 2026-10-21): what tells a
      // cookie window's category header, a button over it, from a choice. Null for a control that says nothing of it.
      const expandedOf = (node) => {
        const state = String(node.getAttribute('aria-expanded') || '').trim().toLowerCase();
        return state === 'true' ? true : (state === 'false' ? false : null);
      };
      // A select lists up to 1000 options and a page up to 2000 in all: a
      // country or time-zone list fits whole, and the report stays bounded.
      // Beside each option's words, its key — a digest of its exact words
      // and value: what the hands find it by again, with its place (review of
      // A3d, round 2, P2-2; review of I-02, N3-P2-1).
      let optionBudget = MAX_PAGE_OPTIONS;
      const optionsOf = (node, tag) => {
        if (tag !== 'select') return null;
        const count = Math.min(node.options.length, MAX_OPTIONS, optionBudget);
        optionBudget -= count;
        const labels = [];
        const optionKeys = [];
        for (let i = 0; i < count; i++) {
          labels.push(ownMasked(node.options[i].text));
          optionKeys.push(optionKeyOf(node.options[i]));
        }
        return { labels, optionKeys };
      };
      // Where activating an element leads: its own address, or the link
      // around it — a "button" inside a mailto: link opens the mail app. A
      // link that acts through the page's script leads nowhere: its click
      // runs the script (ITER-076 I-10).
      const destinationOf = (node) => {
        for (let current = node; current; current = composedParent(current)) {
          if (current.localName === 'a' && current.hasAttribute('href') && typeof current.href === 'string') {
            return scriptLink(current) ? null : String(current.href).slice(0, MAX_URL);
          }
        }
        return null;
      };

      // Owner decision 4 (2026-09-29): a secret field is hidden and the
      // errand goes on; a step stops only where it could send one. A control
      // in a form could when that form could send one: a secret field in it
      // holds something — typed in, or a password the browser filled in
      // (`isFilled`) — one the walk found in it, shadow roots included, one
      // in a frame inside it, or any the page marks secret or whose words name
      // a sign-in or a payment, shown or hidden; it holds a card's field,
      // filled or not (owner decision of 2026-10-03); or what it holds is not
      // known: a frame of another origin inside it, or one not read, or more
      // controls than a form is read to. An empty password, one-time code or
      // field named a sign-in's sends nothing, and the form's other controls
      // are the errand's (2026-10-20: a blind errand stopped at the first
      // field of a practice form whose password was empty) — a field whose
      // words name a sign-in or a payment is that secret's own, the user's to
      // fill, as a withheld one is. With no form, a control could send a
      // secret field that has no form either, and — its script may send any
      // form (review of A3d, round 2, N-P1-2) — a secret field filled in, in a
      // form of the page: an empty login box leaves the page's other controls
      // alone. A link only leaves. A form too big to check counts as holding
      // one, filled in. Whether a form holds a secret field at all, empty or
      // not, is kept too (`holds`): such a form is no pure search (D4). And
      // whether it needs one it holds empty (`needs`, `needsSecret`): every
      // control of it says so, and a press that sends it is the user's
      // sign-in (`SafetyGuard.needsTheUsersSecret`, 2026-10-21).
      const formCensuses = new Map();
      const formCensus = (form) => {
        if (formCensuses.has(form)) return formCensuses.get(form);
        const census = { holds: secretForms.has(form), filled: filledForms.has(form), card: cardForms.has(form),
                         unknown: unknownForms.has(form), needs: neededForms.has(form) };
        const controls = formElementsOf(form);
        if (controls.length > 200) { census.holds = true; census.filled = true; census.unknown = true; }
        for (let i = 0; !census.filled && i < controls.length && i < 200; i++) {
          const control = controls[i];
          const holdsOne = sensitive.has(control) || markedSecret(control) || namesSignInOrPayment(control) !== null;
          if (!holdsOne) continue;
          census.holds = true;
          if (isFilled(control)) census.filled = true;
          if (isCardField(control)) census.card = true;
          if (needsSecret(control)) census.needs = true;
        }
        formCensuses.set(form, census);
        return census;
      };
      let filledOnPage = null;
      const secretFilledOnPage = () => {
        if (filledOnPage === null) {
          filledOnPage = filledForms.size > 0;
          for (let i = 0; !filledOnPage && i < pageForms.length && i < 100; i++) filledOnPage = formCensus(pageForms[i]).filled;
        }
        return filledOnPage;
      };
      const touchesSecretOf = (node, role) => {
        const form = node.form instanceof HTMLFormElement ? node.form : (role === 'link' ? null : enclosingForm(node));
        if (form) {
          const census = formCensus(form);
          return census.filled || census.card || census.unknown || namesSignInOrPayment(node) !== null;
        }
        return role !== 'link' && (formlessSecret || secretFilledOnPage());
      };
      // Whether the form a control sends needs a secret field it holds empty.
      // A link only leaves; a control in no form sends which form is not
      // known, and needs none.
      const formNeedsSecretOf = (node, role) => {
        const form = node.form instanceof HTMLFormElement ? node.form : (role === 'link' ? null : enclosingForm(node));
        return !!form && formCensus(form).needs;
      };

      // Owner decision 6 (review of A3d, round 2, P1-7): a money amount is a
      // currency sign, or an ISO 4217 code, beside a number — in any script.
      // Where a control's own form, or with none its page region, shows one,
      // an irreversible step that commits there is a payment. Read as the
      // page draws it, an input button's words included; what could not be
      // read whole counts as showing one. The expression is the policy's own
      // (`SafetyGuard.amountPattern`), which reads a dialog's words by it too.
      const amountPattern = new RegExp(\#(jsString(SafetyGuard.amountPattern)), 'u');
      const regionRootOf = (node) => node.closest('dialog, [role=dialog], [role=alertdialog], [aria-modal=true]') ||
        node.closest('nav, main, header, footer, aside, [role=navigation], [role=main], [role=banner], ' +
          '[role=contentinfo], [role=complementary]') || document.body || document.documentElement;
      const amounts = new Map();
      const showsAmountIn = (root) => {
        if (amounts.has(root)) return amounts.get(root);
        let shown = false;
        let words = '';
        const stack = [root];
        for (let walked = 0; stack.length > 0 && !shown; walked++) {
          if (walked >= MAX_EXCERPT_NODES || late()) { shown = true; break; }
          const node = stack.pop();
          if (node.nodeType === 3) {
            const place = textPlace(node);
            if (place && readable(place, false)) words += ' ' + String(node.nodeValue);
          } else {
            if (node.nodeType === 1 && node.localName === 'input' &&
                ['submit', 'button', 'reset'].includes((node.type || '').toLowerCase())) {
              words += ' ' + String(inputValue.call(node));
            }
            if (pushDrawnChildren(stack, node, MAX_EXCERPT_NODES - walked - 1)) shown = true;
          }
          if (words.length > 4096) {
            const plain = normalizeSecrets(squeeze(words));
            shown = shown || amountPattern.test(plain);
            words = plain.slice(-32);
          }
        }
        shown = shown || amountPattern.test(normalizeSecrets(squeeze(words)));
        amounts.set(root, shown);
        return shown;
      };
      // A form's own words, and the region around the control: a checkout's
      // total may stand beside the form its button sends (review of I-02,
      // N3-P1-6).
      const showsAmountOf = (node, role, anchor) => {
        const form = node.form instanceof HTMLFormElement ? node.form : (role === 'link' ? null : enclosingForm(node));
        return (!!form && showsAmountIn(form)) || showsAmountIn(regionRootOf(anchor));
      };
      // A total and the control it is for may stand in two documents (Claude
      // review of I-09, kept 3): each control says whether its form or the
      // region around it holds a frame, whose own words the app reads with
      // it (`ObservedPage.merging`).
      const holdingFrames = new Set();
      for (const owner of allFrames) {
        for (let current = composedParent(owner); current; current = composedParent(current)) holdingFrames.add(current);
      }
      const holdsFrameOf = (node, role, anchor) => {
        if (holdingFrames.size === 0) return false;
        const form = node.form instanceof HTMLFormElement ? node.form : (role === 'link' ? null : enclosingForm(node));
        return holdingFrames.has(regionRootOf(anchor)) || (!!form && holdingFrames.has(form));
      };
      // A form as one whole (ITER-076 stage 7, № 69), ported from a reference
      // browser agent's `fieldScope` (`snapshot.js` 346-360, MIT): a field's —
      // and a button's — group is its form; for fields a script gathers
      // without one, the fieldset or `role=form` box around it, else the
      // nearest box below a section of the page that holds more than one
      // field, so a sidebar's search box never joins the content's fields.
      // Known by that box's private key, the same for the document's life;
      // null for none. A control of a form is its form's always — every one
      // the form submits, one joined by its `form` attribute too (review
      // round 2, R2-3); a box is looked for only while time is left.
      const SECTION_TAGS = ['body', 'main', 'article', 'section', 'aside', 'nav', 'header', 'footer'];
      const fieldCounts = new Map();
      const fieldsIn = (box) => {
        if (!fieldCounts.has(box)) {
          fieldCounts.set(box, box.querySelectorAll('input:not([type=hidden]),textarea,select').length);
        }
        return fieldCounts.get(box);
      };
      const groupOf = (node) => {
        const form = ownerForm(node);
        if (form) return keyOf(form);
        if (late()) return null;
        const around = node.closest('fieldset,[role="form"]');
        if (around) return keyOf(around);
        for (let box = composedParent(node), hops = 0; box && hops < 50; box = composedParent(box), hops++) {
          if (box.nodeType !== 1 || SECTION_TAGS.includes(box.localName)) return null;
          if (fieldsIn(box) > 1) return keyOf(box);
        }
        return null;
      };
      // What the page's structure says a field asks for: its `autocomplete`,
      // and whether it is required — `required`, or `aria-required` — for a
      // native field; only `aria-required` for any other.
      const autocompleteOf = (node, tag) => {
        if (!fieldTags.includes(tag)) return null;
        return squeeze(attributeOf.call(node, 'autocomplete') || '').toLowerCase().slice(0, MAX_TEXT) || null;
      };
      const requiredOf = (node, tag) => (fieldTags.includes(tag) && node.required === true) ||
        attributeOf.call(node, 'aria-required') === 'true';

      // Second pass: the report, and beside it the nodes it describes. A
      // secret field is not reported; what identifies it is kept beside the
      // report, in the page only, so the hands can tell a target that turned
      // secret from one that is gone (review of A3, round 1).
      const elements = [];
      const nodes = [];
      const withheld = [];
      // The secret nodes themselves, beside `withheld`: the hands tell a field
      // that focus went to by them (ITER-076 I-07). Never reported.
      const withheldNodes = [];
      // A made-up dropdown's own lists and options: the ones it names, and
      // the ones drawn inside it (review of I-08, F5).
      for (const node of seen) {
        if (!isChoiceWidget(node) || node.localName === 'select') continue;
        for (const list of listsNamedBy(node) || []) choiceLists.add(list);
        for (const inner of node.querySelectorAll('[role~="option"], [role~="listbox"]')) choiceLists.add(inner);
      }
      // Whether an element sits in a list a secret field names, or may name,
      // as its own — however deep: the tree a person sees ends (Claude review
      // of I-09, kept 13).
      const inSecretList = (node) => {
        for (let current = node; current; current = composedParent(current)) {
          if (mayBeSecretList(current)) return true;
        }
        return false;
      };
      // A page with more controls than a report holds (ITER-076 I-10, critic
      // 17; a reference browser agent's `_capped`, `page.py` 318-328, MIT):
      // the ones on screen — whose box meets the viewport — are kept first,
      // then the rest, each part in document order; the report is in
      // document order still.
      const placeOfSeen = new Map(seen.map((node, place) => [node, place]));
      const meetsTheScreen = (node) => {
        const box = node.getBoundingClientRect();
        return box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < innerHeight &&
          box.left < innerWidth;
      };
      const passes = [seen];
      if (seen.length > MAX_ELEMENTS) {
        const shown = [], rest = [];
        for (const node of seen) (meetsTheScreen(node) ? shown : rest).push(node);
        passes.splice(0, 1, shown, rest);
      }
      reporting: for (const pass of passes) {
        // Headings are met in document order within each part.
        headingIndex = -1;
        for (const node of pass) {
          if (elements.length >= MAX_ELEMENTS || late()) { truncated = true; break reporting; }
          // A control a custom select draws inside itself is part of it, not
          // reported.
          if (insideChoice(node)) continue;
          // What a secret field's own list holds is not reported, as what the
          // field holds is not (review of I-08, F4) — nor a label outside it
          // that stands for a box inside it, or inside a secret field: it
          // would be reported as that box, by the box's own words (GLM review
          // of I-09, P1-3).
          if (inSecretList(node)) continue;
          const role = roleOf(node);
          if (!role) continue;
          // A label that stands for its checkbox or radio is reported as that
          // input — its name, state and form — where the label is (ITER-076
          // I-08).
          const subject = sourceOf(node);
          if (subject !== node && insideSensitive(subject)) continue;
          const tag = subject.tagName.toLowerCase();
          const isField = fieldRoles.includes(role) || fieldTags.includes(tag);
          const anchor = anchorOf(node);
          const heading = headingBefore(anchor);
          if (sensitive.has(node)) {
            const form = formInfo(node, role);
            withheldNodes.push(node);
            withheld.push({ key: keyOf(node), role, name: nameOf(node, isField), href: destinationOf(node), heading,
                            context: contextOf(node, ''), formAction: form.formAction, formMethod: form.formMethod });
            continue;
          }
          const text = isField ? '' : boundedText(node);
          const form = formInfo(subject, role);
          const listed = optionsOf(subject, tag);
          // A click opens it (ITER-076 I-08): a field that takes no typing —
          // `readonly` or `aria-readonly`, as a reference browser agent's
          // `editable` reads them — opens its picker, and a made-up dropdown
          // that takes none opens its list. A native select is chosen in.
          const writable = !subject.readOnly && subject.getAttribute('aria-readonly') !== 'true';
          const typedInto = writable &&
            (writingRoles.includes(role) || (role === 'combobox' && (tag === 'input' || tag === 'textarea')));
          elements.push({
            index: elements.length,
            key: keyOf(node),
            role,
            // A checkbox or radio with no name is named by its role, as a
            // reference browser agent names a control with none (`snapshot.js`,
            // `labelOf(e) || rname`), and told apart by its row (review of
            // I-08, F7) — and so is a native select that takes a choice
            // (2026-10-15: a shop's "Order by" select with no label was never
            // offered; a disabled one — itself or by its fieldset — stays
            // unoffered, Codex review P2-5).
            // Any other control with no name stays unoffered.
            name: nameOf(subject, isField)
              || (nativeChoice(subject) || (subject instanceof HTMLSelectElement && !subject.matches(':disabled')) ? role : ''),
            text,
            href: destinationOf(node),
            inputType: tag === 'input' ? (subject.type || 'text').toLowerCase() : null,
            heading,
            region: regionOf(anchor),
            dialogText: dialogTextOf(anchor),
            dialogBlocks: dialogBlocksOf(anchor),
            formEntries: typedInto ? formEntriesOf(subject) : null,
            inSearch: typedInto ? inSearchOf(subject) : null,
            inViewport: onScreen(node),
            context: contextOf(node, text),
            formAction: form.formAction,
            formMethod: form.formMethod,
            formSubmitLabel: form.formSubmitLabel,
            submitUnpressable: form.submitUnpressable,
            submits: form.submits,
            formGrants: form.formGrants,
            options: listed ? listed.labels : null,
            optionKeys: listed ? listed.optionKeys : null,
            checked: checkedOf(subject, tag, role),
            disabled: disabledOf(subject, role),
            value: values.has(subject) ? ownMasked(values.get(subject)) : null,
            touchesSecret: touchesSecretOf(subject, role),
            formNeedsSecret: formNeedsSecretOf(subject, role),
            showsAmount: showsAmountOf(subject, role, anchor),
            holdsFrame: holdsFrameOf(subject, role, anchor),
            opens: tag !== 'select' && !typedInto && (writingRoles.includes(role) || isChoiceWidget(node)),
            // A field typing goes into: writable, a text field or a combobox that takes typing — the fields the
            // hands write in (`aimToWrite`); null for any other (2026-10-21, Codex review 3, P1-1).
            typedInto: typedInto ? true : null,
            expanded: expandedOf(subject),
            needsFile: form.needsFile,
            listOf: null,
            listOwner: null,
            listOwnerEffect: null,
            listForm: null,
            autocomplete: isField ? autocompleteOf(subject, tag) : null,
            required: isField ? requiredOf(subject, tag) : null,
            group: isField || role === 'button' ? groupOf(subject) : null,
            valueKey: values.has(subject) ? digestOf(tag === 'select' ? sentOfList(subject) : values.get(subject)) : null
          });
          nodes.push(node);
        }
      }
      if (passes.length > 1) {
        const reported = nodes.map((node, at) => ({ node, element: elements[at] }))
          .sort((a, b) => placeOfSeen.get(a.node) - placeOfSeen.get(b.node));
        reported.forEach((pair, at) => {
          pair.element.index = at;
          elements[at] = pair.element;
          nodes[at] = pair.node;
        });
      }

      // The page's text, title and address as a person reads them; a page
      // that takes a payment, in any language (owner decision 6 of
      // 2026-09-26: the agent never pays): a card field, a saved card shown
      // by its last digits (Claude review c8, #5), or a payment provider's
      // own frame.
      const text = readExcerpt(MAX_PAGE_TEXT);
      const titleOwn = ownMasked(titleText());
      const urlOwn = addressMasked(location.href);
      const savedCard = /(?:[•*·●∙]{2,}|[xX]{4})[ -]?\d{4}(?!\d)/;
      const paymentHosts = /(^|\.)(stripe\.com|paypal\.com|paypalobjects\.com|braintreegateway\.com|braintree-api\.com|adyen\.com|klarna\.com|checkout\.com|squareup\.com|pay\.google\.com)$/i;
      if (savedCard.test(text)) paymentForm = true;
      const paymentFrames = document.querySelectorAll('iframe[src]');
      for (let i = 0; i < paymentFrames.length && i < 50 && !paymentForm; i++) {
        let host = '';
        try { host = new URL(paymentFrames[i].src).hostname; } catch (error) { host = ''; }
        if (paymentHosts.test(host) && visible(paymentFrames[i])) paymentForm = true;
      }
      // Every string the report holds, cut.
      const final = (value, limit = MAX_TEXT) => (typeof value === 'string' ? value.slice(0, limit) : value);
      for (const element of elements) {
        for (const [field, limit] of [['name', MAX_TEXT], ['text', MAX_TEXT], ['heading', MAX_TEXT],
                                      ['context', MAX_CONTEXT], ['value', MAX_TEXT], ['formSubmitLabel', MAX_TEXT]]) {
          element[field] = final(element[field], limit);
        }
        if (element.context === '') element.context = null;
        if (element.options) element.options = element.options.map((label) => final(label));
      }
      for (const element of withheld) {
        element.name = final(element.name);
        element.heading = final(element.heading);
        element.context = element.context === null ? null : (final(element.context, MAX_CONTEXT) || null);
      }

      // Which made-up dropdown each option is one of (ITER-076 I-08): the one
      // whose list holds it — the list it names by `aria-controls` or
      // `aria-owns`, or the dropdown itself around the option — so the choice
      // a click on it makes is read back on the dropdown.
      // A list several name is the open one's (`aria-expanded`); with no one
      // open, or more than one, whose it is cannot be told (review of I-08,
      // F6): not no one's, which is a list no one names, but ambiguous — its
      // options are not reported (Codex review 3 of I-08, P1-2). Who claims a
      // list is read among every dropdown the walk saw, reported or not: one
      // past the report's limit still claims it, and an owner the report does
      // not hold cannot be bound to (Claude review of I-08's round-2 fix).
      const AMBIGUOUS = -1;
      const reportedAt = new Map(nodes.map((node, index) => [node, index]));
      const boundTo = (owner) => (owner && reportedAt.has(owner) ? reportedAt.get(owner) : AMBIGUOUS);
      const listOwners = new Map();
      const claims = new Map();
      // A dropdown that names more lists than any does claims what is not
      // known: no option is then taken for no one's (Codex review 1 of I-09,
      // P1-2).
      let claimsUnknown = false;
      for (const node of seen) {
        if (!isChoiceWidget(node) || node.localName === 'select') continue;
        listOwners.set(node, boundTo(node));
        const named = listsNamedBy(node);
        if (named === null) { claimsUnknown = true; continue; }
        for (const list of named) {
          if (!claims.has(list)) claims.set(list, []);
          claims.get(list).push(node);
        }
      }
      for (const [list, owners] of claims) {
        const open = owners.filter((node) => (node.getAttribute('aria-expanded') || '').trim().toLowerCase() === 'true');
        listOwners.set(list, boundTo(owners.length === 1 ? owners[0] : open.length === 1 ? open[0] : null));
      }
      // Ownership that is not known is not known for anyone (ITER-076 I-09,
      // review round 3, decision 2; Codex review 2, P1-2): with a claimant
      // whose claims are unknown, any list may be its own — every option is
      // ambiguous, a list another dropdown claims too included.
      nodes.forEach((node, index) => {
        if (elements[index].role !== 'option') return;
        if (claimsUnknown) {
          elements[index].listOf = AMBIGUOUS;
          return;
        }
        for (let current = composedParent(node); current; current = composedParent(current)) {
          if (listOwners.has(current)) {
            elements[index].listOf = listOwners.get(current);
            return;
          }
        }
      });
      // A control whose face is a control of its own name inside it — a
      // suggestion drawn as an option around its article's link — is one
      // control reported twice, and the outer one is never pressed: the hands
      // never click through another control (ITER-076 broad set, 2026-10-07;
      // a reference browser agent's `snapshot.js` leaves out a grid cell
      // around a button). The inner one is reported for both: of the outer
      // one's list, and the one the outer one's options are of — never for a
      // list it is itself an option of.
      const faces = new Map();
      nodes.forEach((node, index) => {
        const name = elements[index].name;
        if (!name) return;
        for (let current = composedParent(node), hops = 0; current && hops < 50;
             current = composedParent(current), hops++) {
          const outer = reportedAt.get(current);
          if (outer === undefined || faces.has(outer) || elements[outer].name !== name ||
              elements[index].listOf === outer) continue;
          faces.set(outer, index);
        }
      });
      const faceOf = (index) => {
        while (faces.has(index)) index = faces.get(index);
        return index;
      };
      for (const outer of Array.from(faces.keys()).sort((a, b) => b - a)) {
        const face = elements[faceOf(outer)];
        if (face.listOf === null && elements[outer].listOf !== AMBIGUOUS) face.listOf = elements[outer].listOf;
      }
      for (const element of elements) {
        if (element.listOf !== null && element.listOf !== AMBIGUOUS) element.listOf = faceOf(element.listOf);
      }
      // Who a dropdown is must be provable (Codex review 2 of I-08, P1-2): an
      // option whose dropdown has a twin — another control the same in every
      // field its identity reads, so neither is offered — could be either's,
      // and is not reported; nor one whose dropdown is itself an option. The
      // rest keep their order; what an option is of follows its place.
      const identityOf = (element) => JSON.stringify([element.role, element.name, element.href, element.heading,
                                                      element.context, element.formAction, element.formMethod]);
      const identities = new Map();
      elements.forEach((element, index) => {
        if (element.listOf !== null || faces.has(index)) return;
        const identity = identityOf(element);
        identities.set(identity, (identities.get(identity) || 0) + 1);
      });
      const kept = elements.map((element, index) => !faces.has(index) && (element.listOf === null ||
        (element.listOf !== AMBIGUOUS && identities.get(identityOf(elements[element.listOf])) === 1)));
      if (kept.includes(false)) {
        const places = new Map();
        const keptElements = [];
        const keptNodes = [];
        elements.forEach((element, index) => {
          if (!kept[index]) return;
          places.set(index, keptElements.length);
          element.index = keptElements.length;
          keptElements.push(element);
          keptNodes.push(nodes[index]);
        });
        for (const element of keptElements) {
          if (element.listOf !== null) element.listOf = places.get(element.listOf);
        }
        elements.splice(0, elements.length, ...keptElements);
        nodes.splice(0, nodes.length, ...keptNodes);
      }
      // An option goes with its dropdown wherever the page draws it (review
      // of I-08, F2): who the dropdown is is part of the option (Codex review
      // 1 of I-08, P1-2), and the form it sends is kept beside the one the
      // option is drawn in — both judged, the stricter counting, both checked
      // at the act (P1-3). Evidence of a secret, an amount or a file the form
      // needs is the option's from either (P2-1). What a No on it refuses
      // reads the dropdown as refusals read every control: without the
      // heading above it or the choice it shows (Codex review 2 of I-08, P2-1)
      // — its fields as they are, for the app to read its addresses as it
      // reads every address (Codex review 3 of I-08, P2-1).
      elements.forEach((element, index) => {
        if (element.listOf === null) return;
        const owner = elements[element.listOf];
        element.listOwner = digestOf(JSON.stringify([owner.role, owner.name, owner.href, owner.heading, owner.context,
                                                     owner.formAction, owner.formMethod]));
        element.listOwnerEffect = { role: owner.role, name: owner.name, context: owner.context, href: owner.href,
                                    formAction: owner.formAction, formMethod: owner.formMethod };
        if (owner.formMethod !== null) {
          element.listForm = { action: owner.formAction, method: owner.formMethod, submitLabel: owner.formSubmitLabel,
                               grants: owner.formGrants };
        }
        element.touchesSecret = element.touchesSecret || owner.touchesSecret;
        element.formNeedsSecret = element.formNeedsSecret || owner.formNeedsSecret;
        element.showsAmount = element.showsAmount || owner.showsAmount;
        element.submitUnpressable = element.submitUnpressable || owner.submitUnpressable;
        const ownerNode = nodes[element.listOf];
        const ownerForm = ownerNode.form instanceof HTMLFormElement ? ownerNode.form : enclosingForm(ownerNode);
        element.needsFile = element.needsFile || (!!ownerForm && wantsFile(ownerForm));
      });


      // Where the page stands, for telling whether an action moved it
      // (ITER-076 A3a). A page can replace `scrollY`: a number that is not
      // one reads as the top.
      const scrolled = Number(window.scrollY);
      const loadedFrom = () => {
        try {
          const entry = performance.getEntriesByType('navigation')[0];
          return entry && typeof entry.name === 'string' && entry.name !== '' ? entry.name.slice(0, MAX_URL) : null;
        } catch (error) {
          return null;
        }
      };
      // What a made-up dropdown shows as its choice: its words, without its
      // options, lists, tree items and fields, as the page draws them. Read by
      // the hands only, in the page, where the choice a click made is read
      // back (ITER-076 I-08); it never reaches the report (ITER-076 2.3). Null
      // for anything else, and when it cannot be read in time.
      const choiceShown = (node) => {
        if (!isChoiceWidget(node) || isEntryField(node)) return null;
        const parts = textNodes(node, (part) => (part !== node && part.nodeType === 1 &&
          (['option', 'listbox', 'treeitem'].includes(firstKnownRole(part)) || isEntryField(part) ||
           styleOf(part).display === 'none') ? [] : drawnChildren(part)));
        return parts === null ? null : collapse(parts.join(' '));
      };
      const owners = Array.from(allFrames);
      return {
        report: {
          // What anyone but the app may see: Jev, the writer, a source link.
          url: urlOwn.slice(0, MAX_URL),
          // Where the tab really is, for the app's own checks; never shown.
          address: String(location.href).slice(0, MAX_URL),
          title: titleOwn.slice(0, MAX_TEXT),
          truncated,
          flags: { loginForm, paymentForm },
          elements,
          // The page's visible text, as jev-ultrafast sends it with every step
          // (`model.py` 110, 6,000 characters): the excerpt's reading, and
          // whether a limit cut it (ITER-076 I-10).
          text: text.slice(0, MAX_PAGE_TEXT),
          textCut: textCut || text.length > MAX_PAGE_TEXT,
          // Where the document was loaded from — its answer's address, which
          // the page's own history calls never change — for the app's own
          // checks, never shown (ITER-076 I-10).
          loadedFrom: loadedFrom(),
          // This document's id (2026-10-21): the app compares element keys only within one document.
          documentID: typeof memory.document === 'string' ? memory.document.slice(0, 64) : null,
          // What the app reads the page and its frames by as one (Codex review
          // 1 of I-09, P1-1; Claude review of I-09, kept 3): how many frames
          // the page holds, whether any stands where a total shows, and what
          // it names any of them (Claude review c11, #4); and whether the
          // page shows a total anywhere: what a frame's holder reads it by.
          frameOwners: {
            count: allFrames.size,
            // The frames a person can see: what may show what an act costs
            // (2026-10-16) — an ad-heavy page keeps bringing frames no one sees.
            shown: Array.from(allFrames).filter((owner) => visible(owner)).length,
            besideAmount: owners.some((owner) => showsAmountOf(owner, 'frame', anchorOf(owner))),
            named: namedFrames
          },
          amountShown: window.top !== window && showsAmountIn(document.body || document.documentElement),
          scrollY: Number.isFinite(scrolled) ? Math.max(0, Math.min(Math.round(scrolled), 10000000)) : 0
        },
        nodes,
        withheld,
        withheldNodes,
        choiceShown
      };
    };
    """#

    /// The observer itself: the walk, and its report as JSON.
    static let source = "(() => {\n" + walk + "return JSON.stringify(observe().report);\n})()"

    /// The most of a control's name, text, heading, value, submit label and
    /// each option, and of a page's title, a report holds; the most of a
    /// control's row (ITER-076 I-09, review round 4, decision 4): what the
    /// observer cuts to (`MAX_TEXT`, `MAX_CONTEXT`).
    static let maxName = 200
    static let maxContext = 80

    /// `text` as a JavaScript string literal.
    static func jsString(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: - A page that has gone quiet (ITER-076 I-07)

    /// How long the page must have been quiet — no mutation, no input event —
    /// before it is read; how long a loading indicator on screen is waited
    /// on; the whole wait; and how often a page that gives one sample at a
    /// time is asked again. A reference browser agent's `_SETTLE_QUIET_SECONDS`,
    /// `_SETTLE_LOADING_SECONDS`, `_SETTLE_SECONDS` and `_SETTLE_POLL_SECONDS`
    /// (`page.py`, MIT).
    static let settleQuiet: Duration = .milliseconds(200)
    static let settleLoading: Duration = .milliseconds(1_500)
    static let settleLimit: Duration = .seconds(5)
    static let settlePoll: Duration = .milliseconds(100)

    /// How long a look and a read wait on a loading indicator an act's settle
    /// gave up on (2026-10-08): a reference browser agent's
    /// `_CAPTURE_LOADING_SECONDS` (`page.py` 231-233, MIT) — a read of
    /// "Loading..." costs a model call and a second read after it, where a
    /// page's own loading may need about 5 seconds.
    static let captureLoading: Duration = .seconds(3)

    /// The page's own title (ITER-076 I-09): the mark the agent's tab shows
    /// before it (`ChromeBridge.tabMark`) is the agent's, and never read back.
    private static let ownTitle = "const TAB_MARK = " + ChromeBridge.markLiteral + ";\n"
        + "const titleText = () => { const title = String(document.title); "
        + "return title.startsWith(TAB_MARK) ? title.slice(TAB_MARK.length) : title; };\n"

    /// The page's quiet clock and its loading indicators (ITER-076 I-07),
    /// ported from a reference browser agent's `snapshot.js` (lines 32-131,
    /// MIT) without its fingerprint: a mutation anywhere in the document —
    /// its open shadow roots and same-origin frames as they are met — or an
    /// input event restarts the clock, which the world the scripts run in
    /// keeps for the document's life. A loading indicator counts only while
    /// it is on screen: most pages keep a hidden one always. Named classes
    /// are a heuristic, and deliberately so: the wait on them is bounded and
    /// ends in reading the page.
    static let quietClock = #"""
    const quiet = (() => {
      const key = '__metawhispQuiet';
      let clock = null;
      try { clock = window[key] || null; } catch (error) { clock = null; }
      if (clock && typeof clock.track === 'function') return clock;
      clock = { lastMutation: performance.now() };
      const roots = new WeakSet();
      const changed = () => { clock.lastMutation = performance.now(); };
      const observer = new MutationObserver(changed);
      clock.track = (root) => {
        if (roots.has(root)) return;
        roots.add(root);
        observer.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
        // Input handlers can defer a navigation or a redraw without mutating
        // yet: the clock starts at the event, so the reply's travel time
        // counts toward settling even when the action changes nothing.
        for (const event of ['input', 'change', 'scroll', 'wheel', 'pointermove', 'pointerdown', 'pointerup',
                             'keydown', 'keyup']) {
          root.addEventListener(event, changed, true);
        }
        changed();
      };
      try { Object.defineProperty(window, key, { value: clock, configurable: true }); } catch (error) {}
      clock.track(document);
      return clock;
    })();
    const LOADING = '[aria-busy="true"],[role="progressbar"],progress:not([value]),' +
      ['spinner', 'loading', 'loader', 'skeleton', 'shimmer']
        .flatMap((name) => ['[class*="' + name + '" i]', '[id*="' + name + '" i]']).join(',');
    const showingIndicator = (e) => {
      if (!e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
      const r = e.getBoundingClientRect();
      const view = e.ownerDocument.defaultView || window;
      return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < view.innerHeight &&
        r.left < view.innerWidth;
    };
    const quietSample = () => {
      let loading = false;
      const include = (root) => {
        quiet.track(root);
        loading = loading || Array.from(root.querySelectorAll(LOADING)).some(showingIndicator);
        for (const e of root.querySelectorAll('*')) {
          if (e.shadowRoot) include(e.shadowRoot);
          if (e.tagName === 'IFRAME' || e.tagName === 'FRAME') {
            let inner = null;
            try { inner = e.contentDocument; } catch (error) { inner = null; }
            if (inner && inner.body) include(inner);
          }
        }
      };
      include(document);
      return { ready: document.readyState === 'interactive' || document.readyState === 'complete',
               quietFor: performance.now() - quiet.lastMutation, hidden: document.hidden, loading };
    };

    """#

    /// Waits, in the page, until it has gone quiet (ITER-076 I-07), and
    /// answers `{"stable": …}` — a reference browser agent's
    /// `_settled_fingerprint` (`page.py` 1432-1456, MIT): ready (`interactive`
    /// or `complete`), quiet for `settleQuiet`, and no loading indicator on
    /// screen — one is waited on for `settleLoading` at most — or `within`
    /// has passed. It polls in the page, one rendered frame first: a menu an
    /// animation frame draws mutates only when that frame runs. A hidden
    /// page draws no frames: it gives one sample, and the caller asks again.
    /// `loadingFor`: what is left of the loading indicator's budget, which
    /// the whole settle owns (Codex review of I-07, P2-5).
    static func settledSource(within limit: Duration, loadingFor loading: Duration = settleLoading) -> String {
        "(() => {\n" + quietClock + "const deadline = performance.now() + \(milliseconds(limit));\n"
            + "const spinning = performance.now() + \(milliseconds(loading));\n"
            + "const QUIET = \(milliseconds(settleQuiet)), POLL = \(milliseconds(settlePoll));\n" + settledWait + "\n})()"
    }

    /// Waits, in the page, while a loading indicator is on screen, and
    /// answers `{"loading": …}` — a reference browser agent's
    /// `_loaded_script` (`page.py` 1457-1467, MIT): only the indicator is
    /// waited on, never quiet — a page that keeps changing, a ticker or a
    /// clock, is readable now. It ends when none is on screen, at `within`,
    /// or at once on a hidden page, which gives one sample a call: the caller
    /// asks again.
    static func loadedSource(within limit: Duration) -> String {
        "(() => {\n" + quietClock + "const deadline = performance.now() + \(milliseconds(limit));\n"
            + "const POLL = \(milliseconds(settlePoll));\n" + loadedWait + "\n})()"
    }

    /// One sample, at once: whether a loading indicator is on screen now,
    /// as `{"loading": …}`.
    static let loadingSample = "(() => {\n" + quietClock + "return JSON.stringify({ loading: quietSample().loading });\n})()"

    private static let loadedWait = #"""
    return new Promise((resolve) => {
      const poll = () => {
        const state = quietSample();
        if (!state.loading || state.hidden || performance.now() >= deadline) {
          resolve(JSON.stringify({ loading: state.loading }));
          return;
        }
        setTimeout(poll, POLL);
      };
      poll();
    });
    """#

    private static let settledWait = #"""
    return new Promise((resolve) => {
      const poll = () => {
        const state = quietSample();
        const calm = state.ready && state.quietFor >= QUIET;
        const stable = calm && (!state.loading || performance.now() >= spinning);
        if (stable || state.hidden || performance.now() >= deadline) {
          resolve(JSON.stringify({ stable }));
          return;
        }
        // Quiet but still spinning polls at the plain interval: a sample walks
        // the document, so aiming at the moment quiet arrives would busy-poll
        // once quiet has already arrived.
        setTimeout(poll, state.ready && !calm ? Math.min(POLL, Math.max(1, QUIET - state.quietFor)) : POLL);
      };
      if (document.hidden) poll(); else requestAnimationFrame(() => setTimeout(poll, 0));
    });
    """#

    private static func milliseconds(_ duration: Duration) -> Int {
        max(0, Int(duration / .milliseconds(1)))
    }

    /// The page's excerpt for the writer as JSON — its address, its title
    /// and at most `limit` characters of its visible main text (§6.6).
    static func excerptSource(limit: Int = 3_000) -> String {
        "(() => {\n" + walk + "const { excerpt, url, title } = observe({ excerpt: \(max(1, limit)), alone: true });\n"
            + "return JSON.stringify({ url, title, text: excerpt });\n})()"
    }

    /// The page for the reader as JSON (ITER-076 brain, step 2): the writer's
    /// excerpt read again — the same words, at most `limit` characters, by
    /// the same rules — each block on a line of its own with its kind; the
    /// page's shown address, how many frames it holds, and what the read met
    /// by kinds and numbers (ITER-076 stage 4a).
    static func blocksSource(limit: Int) -> String {
        "(() => {\n" + walk
            + "const { blocks, url, frames, walk } = observe({ excerpt: \(max(1, limit)), alone: true, lines: true });\n"
            + "return JSON.stringify({ url, frames, blocks, walk });\n})()"
    }
}
