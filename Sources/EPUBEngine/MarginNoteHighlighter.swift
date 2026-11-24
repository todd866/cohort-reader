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
        var desk: String
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
                desk: "#EAE3D5",
                bg: "#FAF7F1",
                fg: "#1B1815",
                muted: "#6D6459",
                accent: "#9E3424",
                border: "#E3DACB",
                hl: "rgba(226, 166, 72, 0.30)"
            )
        case .sepia:
            return Palette(
                desk: "#E4D6BC",
                bg: "#F3EAD8",
                fg: "#2B2218",
                muted: "#6C5B46",
                accent: "#8F3923",
                border: "#DECFAF",
                hl: "rgba(218, 148, 56, 0.30)"
            )
        case .ink:
            return Palette(
                desk: "#0B0A09",
                bg: "#121110",
                fg: "#F0EBE2",
                muted: "#9B958B",
                accent: "#E2735B",
                border: "#2E2B27",
                hl: "rgba(226, 166, 72, 0.26)"
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
            "desk": pal.desk,
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
          html, body {
            width: 100vw !important;
            height: 100vh !important;
            overflow: hidden !important;
            margin: 0 !important;
            padding: 0 !important;
            background: var(--cr-desk) !important;
          }
          #cr-desk {
            width: 100vw;
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            background: var(--cr-desk);
            overflow: hidden;
            box-sizing: border-box;
          }
          #cr-book {
            position: relative;
            background: var(--cr-bg);
            overflow: hidden;
            box-sizing: border-box;
          }
          #cr-book.framed {
            border: 1px solid var(--cr-border);
            border-radius: 8px;
            box-shadow: 0 10px 28px rgba(0, 0, 0, 0.14);
          }
          #cr-spine {
            position: absolute;
            top: 0;
            bottom: 0;
            left: 50%;
            width: 28px;
            transform: translateX(-50%);
            pointer-events: none;
            z-index: 4;
            background: linear-gradient(90deg, transparent, rgba(0,0,0,0.045) 45%, rgba(0,0,0,0.10) 50%, rgba(0,0,0,0.03) 55%, transparent);
          }
          #cr-scroller {
            width: 100%;
            height: 100%;
            overflow: hidden;
            position: relative;
          }
          #cr-content {
            box-sizing: border-box;
            column-fill: auto !important;
            will-change: transform;
            transition: transform 180ms cubic-bezier(0.22, 1, 0.36, 1);
          }
          #cr-content.instant { transition: none !important; }
          #cr-content img, #cr-content svg { max-height: 70vh !important; break-inside: avoid; }
          #cr-content h1, #cr-content h2, #cr-content h3 { break-after: avoid; }
        """ : """
          html {
            margin: 0 !important;
            padding: 0 !important;
          }
          body {
            margin: 0 auto !important;
            padding: 24px var(--cr-pad-x) 88px var(--cr-pad-x) !important;
            max-width: 660px !important;
          }
        """

        let headInject = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no"/>
        <meta http-equiv="Content-Security-Policy" content="default-src 'self' cohortbook: data:; style-src 'unsafe-inline' cohortbook:; script-src 'unsafe-inline'; img-src cohortbook: data:;"/>
        <style id="cohort-reader-theme">
          :root {
            --cr-desk: \(colors.desk);
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
          .cohort-find-hit {
            background: rgba(235, 190, 80, 0.38);
            border-radius: 2px;
            padding: 0 1px;
          }
          .cohort-find-active {
            background: var(--cr-accent);
            color: #ffffff;
            border-radius: 2px;
            padding: 0 2px;
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
          let bookDesk = null;
          let bookShell = null;
          let bookSpine = null;
          let bookScroller = null;
          let bookContent = null;
          let stageW = 0;
          let stageH = 0;
          let colsPerSpread = 1;
          let totalCols = 1;
          let totalSpreads = 1;
          let spreadIdx = 0;
          let wheelLockUntil = 0;

          function currentRoot() {
            return bookContent || document.body;
          }

          function currentFraction() {
            if (IS_PAGINATED) {
              return totalSpreads <= 1 ? 0 : (spreadIdx / (totalSpreads - 1));
            }
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            return Math.min(1, Math.max(0, window.scrollY / maxScroll));
          }

          function ensureBookStage() {
            if (!IS_PAGINATED || !document.body || bookContent) return;
            bookDesk = document.createElement('div');
            bookDesk.id = 'cr-desk';
            bookShell = document.createElement('div');
            bookShell.id = 'cr-book';
            bookSpine = document.createElement('div');
            bookSpine.id = 'cr-spine';
            bookScroller = document.createElement('div');
            bookScroller.id = 'cr-scroller';
            bookContent = document.createElement('div');
            bookContent.id = 'cr-content';
            while (document.body.firstChild) {
              const ch = document.body.firstChild;
              if (ch.nodeName && ch.nodeName.toLowerCase() === 'script') {
                document.body.removeChild(ch);
                continue;
              }
              bookContent.appendChild(ch);
            }
            bookScroller.appendChild(bookContent);
            bookShell.appendChild(bookSpine);
            bookShell.appendChild(bookScroller);
            bookDesk.appendChild(bookShell);
            document.body.appendChild(bookDesk);
          }

          function applySpread(instant) {
            if (!IS_PAGINATED || !bookContent) return;
            spreadIdx = Math.min(totalSpreads - 1, Math.max(0, spreadIdx));
            if (instant) bookContent.classList.add('instant');
            bookContent.style.transform = 'translateX(' + (-spreadIdx * stageW) + 'px)';
            const firstPage = spreadIdx * colsPerSpread + 1;
            const lastPage = Math.min(totalCols, firstPage + colsPerSpread - 1);
            post('pagination', {
              spread: spreadIdx + 1,
              totalSpreads,
              page: firstPage,
              pageEnd: lastPage,
              totalPages: totalCols,
              colsPerView: colsPerSpread
            });
            emitProgress();
            if (instant) {
              requestAnimationFrame(function() {
                if (bookContent) bookContent.classList.remove('instant');
              });
            }
          }

          function layoutPages(preserveFrac) {
            if (!IS_PAGINATED) return;
            ensureBookStage();
            if (!bookShell || !bookScroller || !bookContent) return;
            const deskW = Math.max(280, window.innerWidth);
            const deskH = Math.max(320, window.innerHeight);
            colsPerSpread = deskW >= 860 ? 2 : 1;
            let colW = 300;
            let gutter = 56;
            if (colsPerSpread === 2) {
              const deskMarginX = 48;
              const deskMarginY = 18;
              gutter = 56;
              const maxBookW = Math.min(1040, deskW - 2 * deskMarginX);
              colW = Math.max(260, Math.floor((maxBookW - 2 * gutter) / 2));
              stageW = 2 * colW + 2 * gutter;
              stageH = Math.max(260, deskH - 2 * deskMarginY);
              bookShell.classList.add('framed');
              if (bookSpine) bookSpine.style.display = 'block';
              bookShell.style.width = stageW + 'px';
              bookShell.style.height = stageH + 'px';
              bookContent.style.width = stageW + 'px';
              bookContent.style.height = stageH + 'px';
              bookContent.style.padding = '28px 28px 30px 28px';
            } else {
              const isPhone = deskW < 540;
              stageW = isPhone ? deskW : Math.min(680, deskW - 88);
              stageH = isPhone ? deskH : Math.max(260, deskH - 28);
              bookShell.classList.toggle('framed', !isPhone);
              if (bookSpine) bookSpine.style.display = 'none';
              const cssPad = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--cr-pad-x')) || 22;
              const pad = isPhone ? Math.max(18, Math.min(34, cssPad)) : 32;
              colW = Math.max(200, stageW - 2 * pad);
              gutter = 2 * pad;
              bookShell.style.width = stageW + 'px';
              bookShell.style.height = stageH + 'px';
              bookContent.style.width = stageW + 'px';
              bookContent.style.height = stageH + 'px';
              bookContent.style.padding = (isPhone ? 20 : 28) + 'px ' + pad + 'px 28px ' + pad + 'px';
            }
            bookContent.style.columnWidth = colW + 'px';
            bookContent.style.columnGap = gutter + 'px';
            bookContent.classList.add('instant');
            bookContent.style.transform = 'translateX(0px)';

            const sw = Math.max(stageW, bookScroller.scrollWidth, bookContent.scrollWidth);
            const colStride = Math.max(1, colW + gutter);
            totalCols = Math.max(1, Math.ceil((sw - 12) / colStride));
            totalSpreads = Math.max(1, Math.ceil(totalCols / colsPerSpread));

            if (preserveFrac !== null && preserveFrac !== undefined && !isNaN(preserveFrac)) {
              const f = Math.min(1, Math.max(0, Number(preserveFrac)));
              spreadIdx = f >= 0.999 ? (totalSpreads - 1) : Math.min(totalSpreads - 1, Math.max(0, Math.round(f * (totalSpreads - 1))));
            }
            applySpread(true);
          }

          window.__cohortApplyTypography = function(cfg) {
            if (!cfg || !document.documentElement) return;
            const s = document.documentElement.style;
            if (cfg.desk) s.setProperty('--cr-desk', cfg.desk);
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
            if (IS_PAGINATED) {
              const frac = currentFraction();
              requestAnimationFrame(function() { layoutPages(frac); });
            }
          };

          window.__cohortAddHighlight = function(quote) {
            if (!quote || !currentRoot()) return;
            const clean = String(quote).trim();
            if (!clean) return;
            wrapMatches([{ anchor: clean }], function() {
              const span = document.createElement('span');
              span.className = 'cohort-highlight';
              return span;
            });
          };

          let findHits = [];
          let findIdx = -1;
          let lastFindQuery = '';

          window.__cohortClearFind = function() {
            const old = document.querySelectorAll('.cohort-find-hit');
            for (const el of old) {
              const txt = document.createTextNode(el.textContent || '');
              if (el.parentNode) el.parentNode.replaceChild(txt, el);
            }
            if (currentRoot()) currentRoot().normalize();
            findHits = [];
            findIdx = -1;
            lastFindQuery = '';
            post('findStatus', { current: 0, total: 0 });
          };

          window.__cohortFind = function(query, direction) {
            const q = String(query || '').trim();
            const root = currentRoot();
            if (!q || !root) {
              window.__cohortClearFind();
              return;
            }
            const dir = direction === -1 ? -1 : 1;
            if (q.toLowerCase() !== lastFindQuery.toLowerCase()) {
              window.__cohortClearFind();
              lastFindQuery = q;
              const lowerQ = q.toLowerCase();
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
              const matches = [];
              for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                const raw = n.data || '';
                const low = raw.toLowerCase();
                let pos = 0;
                while (matches.length < 250) {
                  const idx = low.indexOf(lowerQ, pos);
                  if (idx < 0) break;
                  matches.push({ node: n, from: idx, to: idx + lowerQ.length });
                  pos = idx + lowerQ.length;
                }
              }
              matches.sort((a, b) => a.node === b.node ? b.from - a.from : 0);
              for (const m of matches.reverse()) {
                if (!m.node.parentNode) continue;
                const tail = m.node.splitText(m.from);
                tail.splitText(m.to - m.from);
                const span = document.createElement('span');
                span.className = 'cohort-find-hit';
                tail.parentNode.replaceChild(span, tail);
                span.appendChild(tail);
              }
              findHits = Array.from(document.querySelectorAll('.cohort-find-hit'));
              findIdx = findHits.length ? 0 : -1;
            } else if (findHits.length > 0) {
              findHits.forEach(el => el.classList.remove('cohort-find-active'));
              findIdx = ((findIdx + dir) % findHits.length + findHits.length) % findHits.length;
            }
            if (findIdx >= 0 && findHits[findIdx]) {
              const activeEl = findHits[findIdx];
              activeEl.classList.add('cohort-find-active');
              if (IS_PAGINATED && bookContent && stageW > 0) {
                const hitX = activeEl.getBoundingClientRect().left - bookContent.getBoundingClientRect().left;
                spreadIdx = Math.min(totalSpreads - 1, Math.max(0, Math.floor(Math.max(0, hitX) / Math.max(1, stageW))));
                userInteracted = true;
                applySpread(false);
              } else {
                activeEl.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
              }
            }
            post('findStatus', { current: findHits.length ? (findIdx + 1) : 0, total: findHits.length });
          };

          window.__cohortStepPage = function(dir) {
            stepPage(dir >= 0 ? 1 : -1);
          };

          window.__cohortGoToSpread = function(oneBased) {
            if (!IS_PAGINATED) return;
            userInteracted = true;
            spreadIdx = Math.min(totalSpreads - 1, Math.max(0, (Number(oneBased) || 1) - 1));
            applySpread(false);
          };

          window.__cohortScrollBy = function(deltaY) {
            userInteracted = true;
            if (IS_PAGINATED) {
              stepPage(deltaY >= 0 ? 1 : -1);
            } else {
              window.scrollBy({ top: Number(deltaY) || 0, behavior: 'smooth' });
            }
          };

          window.__cohortJumpEdge = function(edge) {
            userInteracted = true;
            if (edge === 'bottom') {
              if (IS_PAGINATED) {
                spreadIdx = totalSpreads - 1;
                applySpread(false);
              } else {
                window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' });
              }
            } else {
              if (IS_PAGINATED) {
                spreadIdx = 0;
                applySpread(false);
              } else {
                window.scrollTo({ top: 0, behavior: 'smooth' });
              }
            }
          };

          function fold(c) {
            if (c === '‘' || c === '’') return "'";
            if (c === '“' || c === '”') return '"';
            if (c === '–' || c === '—') return '-';
            return /\\s/.test(c) ? ' ' : c;
          }

          function buildTextIndex() {
            const root = currentRoot();
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
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
            if (!items.length || !currentRoot()) return;
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
              if (dir < 0) {
                if (spreadIdx <= 0) {
                  post('zoneTap', { zone: 'prev' });
                } else {
                  spreadIdx -= 1;
                  applySpread(false);
                }
              } else {
                if (spreadIdx >= totalSpreads - 1) {
                  post('zoneTap', { zone: 'next' });
                } else {
                  spreadIdx += 1;
                  applySpread(false);
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
            if (tag === 'input' || tag === 'textarea' || (ev.target && ev.target.isContentEditable)) return;
            if (ev.key === 'ArrowRight' || (ev.key === ' ' && !ev.shiftKey) || ev.key === 'l' || ev.key === 'PageDown') {
              ev.preventDefault();
              stepPage(1);
            } else if (ev.key === 'ArrowLeft' || (ev.key === ' ' && ev.shiftKey) || ev.key === 'h' || ev.key === 'PageUp' || ev.key === 'Backspace') {
              ev.preventDefault();
              stepPage(-1);
            } else if (ev.key === 'j' || ev.key === 'ArrowDown') {
              ev.preventDefault();
              if (IS_PAGINATED) { stepPage(1); }
              else { userInteracted = true; window.scrollBy({ top: 140, behavior: 'smooth' }); }
            } else if (ev.key === 'k' || ev.key === 'ArrowUp') {
              ev.preventDefault();
              if (IS_PAGINATED) { stepPage(-1); }
              else { userInteracted = true; window.scrollBy({ top: -140, behavior: 'smooth' }); }
            } else if (ev.key === 'd') {
              ev.preventDefault();
              window.__cohortScrollBy(Math.max(180, window.innerHeight * 0.45));
            } else if (ev.key === 'u') {
              ev.preventDefault();
              window.__cohortScrollBy(-Math.max(180, window.innerHeight * 0.45));
            } else if ((ev.key === 'g' && !ev.shiftKey) || ev.key === 'Home') {
              ev.preventDefault();
              window.__cohortJumpEdge('top');
            } else if (ev.key === 'G' || (ev.key === 'g' && ev.shiftKey) || ev.key === 'End') {
              ev.preventDefault();
              window.__cohortJumpEdge('bottom');
            } else if (['?', '/', ':', 'f', 't', 'm', 'p', 'a', '[', ']', 'H', 'n', 'N', '+', '=', '-', '0', 'Escape'].includes(ev.key)) {
              ev.preventDefault();
              post('keyCommand', { key: ev.key });
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

            window.addEventListener('wheel', function(ev) {
              const absX = Math.abs(ev.deltaX || 0);
              const absY = Math.abs(ev.deltaY || 0);
              if (absX < 24 && absY < 36) return;
              ev.preventDefault();
              const now = Date.now();
              if (now < wheelLockUntil) return;
              wheelLockUntil = now + 240;
              const primary = absX >= absY ? ev.deltaX : ev.deltaY;
              stepPage(primary > 0 ? 1 : -1);
            }, { passive: false });
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
              const full = ((currentRoot() && currentRoot().innerText) || '').trim();
              const totalWords = Math.max(1, full.split(/\\s+/).length);
              return Math.min(1, Math.max(0, wordTarget / totalWords));
            }
            return Math.min(1, Math.max(0, targetFrac));
          }

          function restorePosition() {
            if (userInteracted) return;
            const estFrac = computeTargetFraction();
            if (IS_PAGINATED) {
              layoutPages(estFrac);
              return;
            }
            if (estFrac <= 0) return;
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            window.scrollTo(0, estFrac * maxScroll);
          }

          function emitProgress() {
            const root = currentRoot();
            const words = (((root && root.innerText) || '').trim().split(/\\s+/).filter(Boolean)).length;
            const fraction = currentFraction();
            const wordOffset = Math.round(fraction * words);
            post('progress', { fraction, wordOffset });
          }

          let scrollTimer = null;
          function scheduleProgress() {
            userInteracted = true;
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(emitProgress, 180);
          }

          if (!IS_PAGINATED) {
            window.addEventListener('scroll', scheduleProgress, { passive: true });
          } else {
            let resizeTimer = null;
            window.addEventListener('resize', function() {
              clearTimeout(resizeTimer);
              const frac = currentFraction();
              resizeTimer = setTimeout(function() {
                layoutPages(frac);
              }, 120);
            });
          }

          window.addEventListener('DOMContentLoaded', function() {
            ensureBookStage();
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
