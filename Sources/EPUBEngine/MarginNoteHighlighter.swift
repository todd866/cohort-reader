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
    private struct Palette {
        var bg: String
        var fg: String
        var muted: String
        var accent: String
        var border: String
        var hl: String
    }

    private static func palette(for theme: ReaderTheme) -> Palette {
        switch theme {
        case .auto, .paper:
            return Palette(
                bg: "#FAF8F4",
                fg: "#181614",
                muted: "#6C665E",
                accent: "#553CD1",
                border: "#DFD8CC",
                hl: "rgba(232, 166, 72, 0.28)"
            )
        case .sepia:
            return Palette(
                bg: "#F3EAD8",
                fg: "#2B2218",
                muted: "#6C5B46",
                accent: "#8B4513",
                border: "#DECFAF",
                hl: "rgba(218, 148, 56, 0.30)"
            )
        case .ink:
            return Palette(
                bg: "#111114",
                fg: "#ECE8DF",
                muted: "#9C9790",
                accent: "#8A73F7",
                border: "#303038",
                hl: "rgba(232, 166, 72, 0.26)"
            )
        }
    }

    private static func fontStack(for family: ReaderFontFamily) -> String {
        switch family {
        case .serif:
            return "'Iowan Old Style', 'New York', Georgia, serif"
        case .sans:
            return "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif"
        case .mono:
            return "'SF Mono', ui-monospace, Menlo, monospace"
        }
    }

    public static func typographyUpdateJS(
        typography: ReaderTypography,
        resolvedTheme: ReaderTheme? = nil
    ) -> String {
        let effectiveTheme = resolvedTheme ?? (typography.theme == .auto ? .paper : typography.theme)
        let pal = palette(for: effectiveTheme)
        let cfg: [String: String] = [
            "bg": pal.bg,
            "fg": pal.fg,
            "muted": pal.muted,
            "accent": pal.accent,
            "border": pal.border,
            "hl": pal.hl,
            "font": fontStack(for: typography.fontFamily),
            "size": "\(Int(typography.fontSize))px",
            "lh": String(format: "%.2f", typography.lineHeight),
            "padX": "\(typography.marginWidth.horizontalPaddingPx)px",
            "align": typography.textAlignment.cssTextAlign,
        ]
        let jsonData = (try? JSONEncoder().encode(cfg)) ?? Data("{}".utf8)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        return "window.__cohortApplyTypography && window.__cohortApplyTypography(\(json));"
    }

    public static func composeChapterHTML(
        rawXHTML: String,
        typography: ReaderTypography,
        notes: [MarginNote],
        initialFraction: Double,
        initialWordOffset: Int?,
        resolvedTheme: ReaderTheme? = nil,
        highlights: [ReadingHighlight] = []
    ) -> String {
        let effectiveTheme = resolvedTheme ?? (typography.theme == .auto ? .paper : typography.theme)
        let colors = palette(for: effectiveTheme)
        let stack = fontStack(for: typography.fontFamily)
        let padX = typography.marginWidth.horizontalPaddingPx
        let textAlign = typography.textAlignment.cssTextAlign

        let notesJSONData = (try? JSONEncoder().encode(notes)) ?? Data("[]".utf8)
        let notesJSON = String(data: notesJSONData, encoding: .utf8) ?? "[]"
        let hlQuotes = highlights.map(\.quote).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let highlightsJSONData = (try? JSONEncoder().encode(hlQuotes)) ?? Data("[]".utf8)
        let highlightsJSON = String(data: highlightsJSONData, encoding: .utf8) ?? "[]"
        let wordOffsetJS = initialWordOffset.map(String.init) ?? "null"
        let isPaginated = (typography.readingFlow == .paginated)

        let paginatedCSS = isPaginated ? """
          html {
            height: 100vh !important;
            overflow: hidden !important;
            margin: 0 !important;
            padding: 0 !important;
          }
          body {
            height: calc(100vh - 8px) !important;
            width: 100vw !important;
            max-width: none !important;
            box-sizing: border-box !important;
            margin: 0 !important;
            padding: 18px var(--cr-pad-x) 24px var(--cr-pad-x) !important;
            column-width: calc(100vw - 2 * var(--cr-pad-x)) !important;
            column-gap: calc(2 * var(--cr-pad-x)) !important;
            column-fill: auto !important;
            overflow-x: auto !important;
            overflow-y: hidden !important;
            scroll-snap-type: x mandatory;
            -webkit-overflow-scrolling: touch;
          }
          img, svg { max-height: 74vh !important; }
        """ : """
          html, body {
            margin: 0 auto !important;
            padding: 18px var(--cr-pad-x) 88px var(--cr-pad-x) !important;
            max-width: 68ch !important;
          }
        """

        let headInject = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"/>
        <meta http-equiv="Content-Security-Policy" content="default-src 'self' cohortbook: data:; style-src 'unsafe-inline' cohortbook:; script-src 'unsafe-inline'; img-src cohortbook: data:;"/>
        <style id="cohort-reader-theme">
          :root {
            --cr-bg: \(colors.bg);
            --cr-fg: \(colors.fg);
            --cr-muted: \(colors.muted);
            --cr-accent: \(colors.accent);
            --cr-border: \(colors.border);
            --cr-hl: \(colors.hl);
            --cr-font: \(stack);
            --cr-size: \(Int(typography.fontSize))px;
            --cr-lh: \(String(format: "%.2f", typography.lineHeight));
            --cr-pad-x: \(padX)px;
            --cr-align: \(textAlign);
          }
          html, body {
            background: var(--cr-bg) !important;
            color: var(--cr-fg) !important;
            font-family: var(--cr-font) !important;
            font-size: var(--cr-size) !important;
            line-height: var(--cr-lh) !important;
            -webkit-text-size-adjust: 100%;
          }
          \(paginatedCSS)
          h1, h2, h3, h4 {
            font-weight: 600;
            line-height: 1.25;
            margin-top: 1.2em;
            margin-bottom: 0.55em;
            color: var(--cr-fg);
          }
          p { margin: 0 0 0.95em 0; text-align: var(--cr-align); hyphens: auto; -webkit-hyphens: auto; }
          img, svg { max-width: 100% !important; height: auto !important; display: block; margin: 1em auto; }
          table { max-width: 100%; display: block; overflow-x: auto; }
          pre, code { white-space: pre-wrap; word-break: break-word; }
          a { color: var(--cr-accent); }
          .subtitle { color: var(--cr-muted); font-size: 0.9em; }
          .cohort-highlight {
            background: var(--cr-hl);
            border-bottom: 1.5px solid rgba(212, 138, 38, 0.72);
            border-radius: 2px;
            padding: 0 1px;
          }
          .cohort-note {
            text-decoration: underline dotted var(--cr-accent);
            text-underline-offset: 3px;
            text-decoration-thickness: 1.5px;
            background: color-mix(in srgb, var(--cr-accent) 12%, transparent);
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
          const HIGHLIGHTS = \(highlightsJSON);
          const IS_PAGINATED = \(isPaginated ? "true" : "false");
          let userInteracted = false;

          window.__cohortApplyTypography = function(cfg) {
            if (!cfg || !document.documentElement) return;
            const s = document.documentElement.style;
            if (cfg.bg) s.setProperty('--cr-bg', cfg.bg);
            if (cfg.fg) s.setProperty('--cr-fg', cfg.fg);
            if (cfg.muted) s.setProperty('--cr-muted', cfg.muted);
            if (cfg.accent) s.setProperty('--cr-accent', cfg.accent);
            if (cfg.border) s.setProperty('--cr-border', cfg.border);
            if (cfg.hl) s.setProperty('--cr-hl', cfg.hl);
            if (cfg.font) s.setProperty('--cr-font', cfg.font);
            if (cfg.size) s.setProperty('--cr-size', cfg.size);
            if (cfg.lh) s.setProperty('--cr-lh', cfg.lh);
            if (cfg.padX) s.setProperty('--cr-pad-x', cfg.padX);
            if (cfg.align) s.setProperty('--cr-align', cfg.align);
          };

          window.__cohortAddHighlight = function(quote) {
            if (!quote || !document.body) return;
            const clean = String(quote).trim();
            if (!clean) return;
            wrapMatches([{ anchor: clean }], function() {
              const span = document.createElement('span');
              span.className = 'cohort-highlight';
              return span;
            });
          };

          function fold(c) {
            if (c === '‘' || c === '’') return "'";
            if (c === '“' || c === '”') return '"';
            if (c === '–' || c === '—') return '-';
            return /\\s/.test(c) ? ' ' : c;
          }

          function buildTextIndex() {
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
            return { nodes, text, origin };
          }

          function wrapMatches(items, makeSpan) {
            if (!items.length || !document.body) return;
            const idx = buildTextIndex();
            const wraps = [];
            for (const entry of items) {
              const foldedAnchor = Array.from(entry.anchor || '').map(fold).join('').replace(/\\s+/g, ' ').trim();
              if (!foldedAnchor) continue;
              const at = idx.text.indexOf(foldedAnchor);
              if (at < 0) continue;
              const end = at + foldedAnchor.length - 1;
              let [nIdx, from] = idx.origin[at];
              const [lastNode, lastOff] = idx.origin[end];
              for (let k = nIdx; k <= lastNode; k++) {
                const to = k === lastNode ? lastOff + 1 : idx.nodes[k].data.length;
                if (to > from) wraps.push({ node: k, from, to, entry });
                from = 0;
              }
            }
            wraps.sort((a, b) => a.node - b.node || b.from - a.from);
            for (const w of wraps) {
              const node = idx.nodes[w.node];
              if (!node || !node.parentNode) continue;
              const tail = node.splitText(w.from);
              tail.splitText(w.to - w.from);
              const span = makeSpan(w.entry);
              tail.parentNode.replaceChild(span, tail);
              span.appendChild(tail);
            }
          }

          function markHighlights() {
            if (!HIGHLIGHTS.length || !document.body || document.body.dataset.cohortHighlights) return;
            document.body.dataset.cohortHighlights = '1';
            wrapMatches(HIGHLIGHTS.map(q => ({ anchor: q })), function() {
              const span = document.createElement('span');
              span.className = 'cohort-highlight';
              return span;
            });
          }

          function markNotes() {
            if (!NOTES.length || !document.body || document.body.dataset.cohortNotes) return;
            document.body.dataset.cohortNotes = '1';
            wrapMatches(NOTES, function(note) {
              const span = document.createElement('span');
              span.className = 'cohort-note';
              span.dataset.note = note.id;
              return span;
            });
          }

          function post(type, payload) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cohortReader) {
                window.webkit.messageHandlers.cohortReader.postMessage(Object.assign({ type }, payload));
              }
            } catch (_) {}
          }

          function stepPage(dir) {
            userInteracted = true;
            if (IS_PAGINATED) {
              const el = document.body;
              const step = Math.max(200, window.innerWidth);
              const maxX = Math.max(0, el.scrollWidth - window.innerWidth);
              if (dir < 0) {
                if (el.scrollLeft <= 10) {
                  post('zoneTap', { zone: 'prev' });
                } else {
                  const target = Math.max(0, Math.round((el.scrollLeft - step) / step) * step);
                  el.scrollTo({ left: target, behavior: 'smooth' });
                }
              } else {
                if (el.scrollLeft >= maxX - 10) {
                  post('zoneTap', { zone: 'next' });
                } else {
                  const target = Math.min(maxX, Math.round((el.scrollLeft + step) / step) * step);
                  el.scrollTo({ left: target, behavior: 'smooth' });
                }
              }
              return;
            }
            if (dir < 0) {
              if (window.scrollY <= 8) {
                post('zoneTap', { zone: 'prev' });
              } else {
                window.scrollBy({ top: -window.innerHeight * 0.85, behavior: 'smooth' });
              }
            } else {
              const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
              if (window.scrollY >= maxY - 8) {
                post('zoneTap', { zone: 'next' });
              } else {
                window.scrollBy({ top: window.innerHeight * 0.85, behavior: 'smooth' });
              }
            }
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
              stepPage(-1);
            } else if (ratio > 0.82) {
              stepPage(1);
            } else {
              post('zoneTap', { zone: 'center' });
            }
          });

          document.addEventListener('keydown', function(ev) {
            if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
            const tag = ev.target && ev.target.tagName ? ev.target.tagName.toLowerCase() : '';
            if (tag === 'input' || tag === 'textarea') return;
            if (ev.key === 'ArrowRight' || (ev.key === ' ' && !ev.shiftKey)) {
              ev.preventDefault();
              stepPage(1);
            } else if (ev.key === 'ArrowLeft' || (ev.key === ' ' && ev.shiftKey)) {
              ev.preventDefault();
              stepPage(-1);
            } else if (ev.key === 'j' && !IS_PAGINATED) {
              userInteracted = true;
              window.scrollBy({ top: 120, behavior: 'smooth' });
            } else if (ev.key === 'k' && !IS_PAGINATED) {
              userInteracted = true;
              window.scrollBy({ top: -120, behavior: 'smooth' });
            }
          });

          if (IS_PAGINATED) {
            let touchStartX = null;
            let touchStartY = null;
            document.addEventListener('touchstart', function(ev) {
              if (ev.touches && ev.touches.length === 1) {
                touchStartX = ev.touches[0].clientX;
                touchStartY = ev.touches[0].clientY;
              }
            }, { passive: true });
            document.addEventListener('touchend', function(ev) {
              if (touchStartX === null || !ev.changedTouches || !ev.changedTouches.length) return;
              const dx = ev.changedTouches[0].clientX - touchStartX;
              const dy = ev.changedTouches[0].clientY - touchStartY;
              touchStartX = null;
              touchStartY = null;
              if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.4) {
                stepPage(dx < 0 ? 1 : -1);
              }
            }, { passive: true });
          }

          document.addEventListener('selectionchange', function() {
            const sel = window.getSelection ? String(window.getSelection()).trim() : '';
            if (sel.length >= 12) {
              post('selection', { text: sel.slice(0, 800) });
            } else if (sel.length === 0) {
              post('selection', { text: '' });
            }
          });

          function computeTargetFraction() {
            const targetFrac = \(initialFraction);
            const wordTarget = \(wordOffsetJS);
            if (typeof wordTarget === 'number' && wordTarget > 0) {
              const full = (document.body.innerText || '').trim();
              const totalWords = Math.max(1, full.split(/\\s+/).length);
              return Math.min(1, Math.max(0, wordTarget / totalWords));
            }
            return Math.min(1, Math.max(0, targetFrac));
          }

          function restorePosition() {
            if (userInteracted) return;
            const estFrac = computeTargetFraction();
            if (estFrac <= 0) return;
            if (IS_PAGINATED) {
              const el = document.body;
              const step = Math.max(200, window.innerWidth);
              const maxX = Math.max(0, el.scrollWidth - window.innerWidth);
              const pageIdx = Math.round((estFrac * maxX) / step);
              el.scrollLeft = Math.min(maxX, pageIdx * step);
            } else {
              const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
              window.scrollTo(0, estFrac * maxScroll);
            }
          }

          function emitProgress() {
            const words = ((document.body.innerText || '').trim().split(/\\s+/).filter(Boolean)).length;
            let fraction = 0;
            if (IS_PAGINATED) {
              const maxX = Math.max(1, document.body.scrollWidth - window.innerWidth);
              fraction = Math.min(1, Math.max(0, document.body.scrollLeft / maxX));
            } else {
              const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
              fraction = Math.min(1, Math.max(0, window.scrollY / maxScroll));
            }
            const wordOffset = Math.round(fraction * words);
            post('progress', { fraction, wordOffset });
          }

          let scrollTimer = null;
          function scheduleProgress() {
            userInteracted = true;
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(emitProgress, 180);
          }

          window.addEventListener('scroll', scheduleProgress, { passive: true });
          if (IS_PAGINATED && document.body) {
            document.body.addEventListener('scroll', scheduleProgress, { passive: true });
          }

          window.addEventListener('DOMContentLoaded', function() {
            markHighlights();
            markNotes();
            requestAnimationFrame(restorePosition);
          });
          window.addEventListener('load', function() {
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
