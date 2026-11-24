import Foundation
import ReaderModel

/// Clean Swift + injected-JS margin note anchor matcher mirroring `paperlibrary-away/lib/notes.ts`.
public enum MarginNoteHighlighter {
    public struct AnchorHit: Sendable, Hashable {
        public var noteId: String
        public var range: Range<String.Index>
    }

    /// Fold curly quotes, dashes, and runs of whitespace the same way the margin-note annotator does.
    public static func fold(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for ch in input {
            let mapped: Character
            switch ch {
            case "\u{2018}", "\u{2019}": mapped = "'"
            case "\u{201C}", "\u{201D}": mapped = "\""
            case "\u{2013}", "\u{2014}": mapped = "-"
            default:
                mapped = ch.isWhitespace ? " " : ch
            }
            if mapped == " " && (out.isEmpty || out.last == " ") {
                continue
            }
            out.append(mapped)
        }
        return out
    }

    public static func matchingNotes(inText text: String, notes: [MarginNote]) -> [MarginNote] {
        let foldedText = fold(text)
        return notes.filter { note in
            let anchor = fold(note.anchor)
            return !anchor.isEmpty && foldedText.contains(anchor)
        }
    }
}

public enum EPUBHTMLComposer {
    public static func composeChapterHTML(
        rawXHTML: String,
        typography: ReaderTypography,
        notes: [MarginNote],
        initialFraction: Double,
        initialWordOffset: Int?
    ) -> String {
        let colors: (bg: String, fg: String, muted: String, accent: String, border: String)
        switch typography.theme {
        case .paper:
            colors = ("#FAF9F6", "#16181D", "#5B6472", "#5B21B6", "#E2E5EC")
        case .sepia:
            colors = ("#F3EAD8", "#2B2218", "#6C5B46", "#8B4513", "#DECFAF")
        case .ink:
            colors = ("#12151B", "#E8ECF4", "#8F9AA8", "#A78BFA", "#262C37")
        }

        let fontStack: String
        switch typography.fontFamily {
        case .serif:
            fontStack = "'Iowan Old Style', 'New York', Georgia, serif"
        case .sans:
            fontStack = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif"
        case .mono:
            fontStack = "'SF Mono', ui-monospace, Menlo, monospace"
        }

        let notesJSONData = (try? JSONEncoder().encode(notes)) ?? Data("[]".utf8)
        let notesJSON = String(data: notesJSONData, encoding: .utf8) ?? "[]"
        let wordOffsetJS = initialWordOffset.map(String.init) ?? "null"

        let headInject = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"/>
        <meta http-equiv="Content-Security-Policy" content="default-src 'self' cohortbook: data:; style-src 'unsafe-inline' cohortbook:; script-src 'unsafe-inline'; img-src cohortbook: data:;"/>
        <style id="cohort-reader-theme">
          html, body {
            background: \(colors.bg) !important;
            color: \(colors.fg) !important;
            font-family: \(fontStack) !important;
            font-size: \(Int(typography.fontSize))px !important;
            line-height: \(typography.lineHeight) !important;
            margin: 0 auto !important;
            padding: 18px 20px 88px 20px !important;
            max-width: 68ch !important;
            -webkit-text-size-adjust: 100%;
          }
          h1, h2, h3, h4 {
            font-weight: 600;
            line-height: 1.25;
            margin-top: 1.2em;
            margin-bottom: 0.55em;
          }
          p { margin: 0 0 0.95em 0; hyphens: auto; -webkit-hyphens: auto; }
          img, svg { max-width: 100% !important; height: auto !important; display: block; margin: 1em auto; }
          table { max-width: 100%; display: block; overflow-x: auto; }
          pre, code { white-space: pre-wrap; word-break: break-word; }
          a { color: \(colors.accent); }
          .subtitle { color: \(colors.muted); font-size: 0.9em; }
          .cohort-note {
            text-decoration: underline dotted \(colors.accent);
            text-underline-offset: 3px;
            text-decoration-thickness: 1.5px;
            background: color-mix(in srgb, \(colors.accent) 10%, transparent);
            border-radius: 3px;
            padding: 0 2px;
            cursor: pointer;
          }
        </style>
        """

        let scriptInject = """
        <script>
        (function() {
          const NOTES = \(notesJSON);
          function fold(c) {
            if (c === '‘' || c === '’') return "'";
            if (c === '“' || c === '”') return '"';
            if (c === '–' || c === '—') return '-';
            return /\\s/.test(c) ? ' ' : c;
          }
          function markNotes() {
            if (!NOTES.length || !document.body || document.body.dataset.cohortNotes) return;
            document.body.dataset.cohortNotes = '1';
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            const nodes = [];
            let text = '';
            const origin = [];
            for (let n = walker.nextNode(); n; n = walker.nextNode()) {
              const idx = nodes.push(n) - 1;
              const val = n.data;
              for (let i = 0; i < val.length; i++) {
                const c = fold(val[i]);
                if (c === ' ' && (text.length === 0 || text.endsWith(' '))) continue;
                text += c;
                origin.push([idx, i]);
              }
            }
            const wraps = [];
            for (const note of NOTES) {
              const foldedAnchor = Array.from(note.anchor || '').map(fold).join('').replace(/\\s+/g, ' ').trim();
              if (!foldedAnchor) continue;
              const at = text.indexOf(foldedAnchor);
              if (at < 0) continue;
              const end = at + foldedAnchor.length - 1;
              let [nIdx, from] = origin[at];
              const [lastNode, lastOff] = origin[end];
              for (let k = nIdx; k <= lastNode; k++) {
                const to = k === lastNode ? lastOff + 1 : nodes[k].data.length;
                if (to > from) wraps.push({ node: k, from, to, id: note.id });
                from = 0;
              }
            }
            wraps.sort((a, b) => a.node - b.node || b.from - a.from);
            for (const w of wraps) {
              const node = nodes[w.node];
              const tail = node.splitText(w.from);
              tail.splitText(w.to - w.from);
              const span = document.createElement('span');
              span.className = 'cohort-note';
              span.dataset.note = w.id;
              tail.parentNode.replaceChild(span, tail);
              span.appendChild(tail);
            }
          }

          function post(type, payload) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cohortReader) {
                window.webkit.messageHandlers.cohortReader.postMessage(Object.assign({ type }, payload));
              }
            } catch (_) {}
          }

          document.addEventListener('click', function(ev) {
            const target = ev.target && ev.target.closest ? ev.target.closest('.cohort-note') : null;
            if (target && target.dataset.note) {
              ev.preventDefault();
              post('noteTap', { noteId: target.dataset.note });
              return;
            }
            const link = ev.target && ev.target.closest ? ev.target.closest('a') : null;
            if (link) return;
            const sel = window.getSelection ? String(window.getSelection()).trim() : '';
            if (sel.length > 0) return;
            const w = Math.max(1, window.innerWidth);
            const ratio = ev.clientX / w;
            if (ratio < 0.18) {
              if (window.scrollY <= 8) {
                post('zoneTap', { zone: 'prev' });
              } else {
                window.scrollBy({ top: -window.innerHeight * 0.85, behavior: 'smooth' });
              }
            } else if (ratio > 0.82) {
              const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
              if (window.scrollY >= maxY - 8) {
                post('zoneTap', { zone: 'next' });
              } else {
                window.scrollBy({ top: window.innerHeight * 0.85, behavior: 'smooth' });
              }
            } else {
              post('zoneTap', { zone: 'center' });
            }
          });

          document.addEventListener('selectionchange', function() {
            const sel = window.getSelection ? String(window.getSelection()).trim() : '';
            if (sel.length >= 12) {
              post('selection', { text: sel.slice(0, 800) });
            } else if (sel.length === 0) {
              post('selection', { text: '' });
            }
          });

          function restorePosition() {
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            const targetFrac = \(initialFraction);
            const wordTarget = \(wordOffsetJS);
            if (typeof wordTarget === 'number' && wordTarget > 0) {
              const full = (document.body.innerText || '').trim();
              const totalWords = Math.max(1, full.split(/\\s+/).length);
              const estFrac = Math.min(1, Math.max(0, wordTarget / totalWords));
              window.scrollTo(0, estFrac * maxScroll);
            } else if (targetFrac > 0) {
              window.scrollTo(0, targetFrac * maxScroll);
            }
          }

          let scrollTimer = null;
          window.addEventListener('scroll', function() {
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(function() {
              const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
              const fraction = Math.min(1, Math.max(0, window.scrollY / maxScroll));
              const words = ((document.body.innerText || '').trim().split(/\\s+/).filter(Boolean)).length;
              const wordOffset = Math.round(fraction * words);
              post('progress', { fraction, wordOffset });
            }, 180);
          }, { passive: true });

          window.addEventListener('DOMContentLoaded', function() {
            markNotes();
            requestAnimationFrame(restorePosition);
          });
        })();
        </script>
        """

        var html = rawXHTML
        if let headRange = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: headInject, at: headRange.lowerBound)
        } else if let bodyStart = html.range(of: "<body", options: .caseInsensitive) {
            html.insert(contentsOf: "<head>\(headInject)</head>", at: bodyStart.lowerBound)
        } else {
            html = "<!DOCTYPE html><html><head>\(headInject)</head><body>\(html)</body></html>"
        }

        if let bodyEnd = html.range(of: "</body>", options: .caseInsensitive) {
            html.insert(contentsOf: scriptInject, at: bodyEnd.lowerBound)
        } else {
            html += scriptInject
        }
        return html
    }
}
