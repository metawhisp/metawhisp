import Foundation

/// The page reads behind the brain's free actions (browser-use's `search_page`, `find_elements`, `find_text` and
/// `extract`, MIT). `search_page` and `extract` read the page as the app's reader reads it — no secret field's
/// words, no text drawn as dots (Codex review of 2026-10-19, P1-4); the scripts here only read, return one string,
/// and never return a field's value or any part of a secret field.
enum BrainScripts {
    /// The reference's free-text extraction instruction (`browser_use/tools/service.py`, `extract`).
    static let extractInstruction = """
    You are an expert at extracting data from the text of a webpage.
    <input>
    You will be given a query and the text of a webpage.
    </input>
    <instructions>
    - You are tasked to extract information from the webpage that is relevant to the query.
    - You should ONLY use the information available in the webpage to answer the query. Do not make up information or provide guess from your own knowledge.
    - If the information relevant to the query is not available in the page, your response should mention that.
    - If the query asks for all items, products, etc., make sure to directly list all of them.
    - If the content was truncated and you need more information, note that the user can use start_from_char parameter to continue from where truncation occurred.
    </instructions>
    <output>
    - Your output should present ALL the information relevant to the query in a concise way.
    - Do not answer in conversational format - directly output the relevant information or that the information is unavailable.
    </output>
    """

    /// A string as a JavaScript literal.
    static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// The fields whose words are never read: passwords, card details, one-time codes, hidden fields, and any element
    /// drawn as dots, as the observer withholds them (Codex review of 2026-10-19, P1-4).
    static let secretField = """
    (e) => { if (!e || !e.matches) return false;
      const type = (e.getAttribute('type') || '').toLowerCase();
      const auto = (e.getAttribute('autocomplete') || '').toLowerCase();
      if (e.tagName === 'INPUT' && ['password', 'hidden'].includes(type)) return true;
      if (/cc-|one-time-code|current-password|new-password/.test(auto)) return true;
      const style = getComputedStyle(e);
      return (style.webkitTextSecurity || style.getPropertyValue('-webkit-text-security') || 'none') !== 'none'; }
    """

    /// `text` from `start`, at most `chars` characters, with where it stands.
    static func part(of text: String, from start: Int, chars: Int) -> String {
        let from = max(0, min(start, text.count))
        let part = String(text.dropFirst(from).prefix(chars))
        return "Characters \(from) to \(from + part.count) of \(text.count)\n" + part
    }

    /// Every match of `pattern` in `text` — the page as the reader reads it — with its context (the reference's
    /// `search_page`, run on the app's own reading of the page instead of the page's raw text). The pattern is plain
    /// text: a regular expression could run without end on the app's own thread, and Stop with it (Codex review 2 of
    /// 2026-10-19, P1); an escaped literal has no quantifier to backtrack on.
    static func search(_ text: String, pattern: String, caseSensitive: Bool, contextChars: Int, maxResults: Int) -> String {
        guard !pattern.isEmpty, pattern.count <= 500, let expression = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: pattern), options: caseSensitive ? [] : [.caseInsensitive])
        else { return "Invalid pattern." }
        let whole = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: whole.length))
        guard !matches.isEmpty else { return "No matches." }
        let shown = matches.prefix(max(1, maxResults)).enumerated().map { number, match in
            let from = max(0, match.range.location - max(0, contextChars))
            let to = min(whole.length, match.range.location + match.range.length + max(0, contextChars))
            let around = whole.substring(with: NSRange(location: from, length: to - from))
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return "\(number + 1). ...\(around)..."
        }
        return "\(matches.count) match(es)" + (matches.count > shown.count ? ", first \(shown.count) shown" : "") + ":\n"
            + shown.joined(separator: "\n")
    }

    /// Scrolls to the first text holding `text`, case-insensitive: "true" or "false". Returns no words.
    static func scrollToText(_ text: String) -> String {
        """
        (() => { const want = \(literal(text)).toLowerCase();
          const walk = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
          for (let node = walk.nextNode(); node; node = walk.nextNode()) {
            if ((node.textContent || '').toLowerCase().includes(want) && node.parentElement) {
              node.parentElement.scrollIntoView({block: 'center'}); return 'true'; } }
          return 'false'; })()
        """
    }

    /// The elements `selector` matches: tag, text and the asked attributes — none of a secret field, no field's
    /// value, no text of an element that holds words drawn as dots.
    static func findElements(selector: String, attributes: [String]?, maxResults: Int, includeText: Bool) -> String {
        let names = (try? JSONSerialization.data(withJSONObject: attributes ?? [])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
        (() => { const secret = \(secretField);
          let found;
          try { found = Array.from(document.querySelectorAll(\(literal(selector)))); }
          catch (e) { return 'Invalid selector: ' + e.message; }
          const names = \(names);
          const field = (e) => ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName);
          // Every secret of the page, found once: an element inside one, or holding one, is not read at all (Codex
          // review 2 of 2026-10-19, P1: a code's digits in spans inside a one-time-code box).
          const secrets = Array.from(document.querySelectorAll('*')).filter(secret);
          const touches = (e) => secrets.some((s) => s === e || s.contains(e) || e.contains(s));
          const out = found.slice(0, \(max(1, maxResults))).map((e, i) => {
            let line = (i + 1) + '. <' + e.tagName.toLowerCase() + '>';
            if (touches(e)) return line + ' [a secret field, or inside or around one: not read]';
            for (const n of names) {
              if (field(e) && ['value', 'data-value'].includes(n.toLowerCase())) continue;
              const v = e.getAttribute(n); if (v !== null) line += ' ' + n + '="' + v.slice(0, 200) + '"'; }
            if (\(includeText ? "true" : "false")) {
              const t = (e.innerText || e.textContent || '').trim().replace(/\\s+/g, ' ');
              if (t) line += ' ' + t.slice(0, 150); }
            return line; });
          return found.length + ' element(s)' + (found.length > out.length ? ', first ' + out.length + ' shown' : '') + ':\\n' + out.join('\\n'); })()
        """
    }
}
