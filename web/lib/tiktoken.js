/* Tiktoken (pure-JS) for GPT-5.x (o200k_base).
 * Self-contained classic script — no bundler, no ES modules, works under
 * WebKit file://. The ~2.3MB o200k_base ranks are lazy-loaded by injecting a
 * <script> tag on first use, so the app stays fast to load.
 *
 * Vendored from js-tiktoken / base64-js (MIT). */

(function () {
    'use strict';

    // ── base64 decoder (from base64-js, MIT) ───────────────────────
    var lookup = [];
    var revLookup = [];
    var Arr = typeof Uint8Array !== 'undefined' ? Uint8Array : Array;
    var code = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    for (var i = 0, len = code.length; i < len; ++i) {
        lookup[i] = code[i];
        revLookup[code.charCodeAt(i)] = i;
    }
    revLookup['-'.charCodeAt(0)] = 62;
    revLookup['_'.charCodeAt(0)] = 63;

    function getLens(b64) {
        var len = b64.length;
        if (len % 4 > 0) throw new Error('Invalid string. Length must be a multiple of 4');
        var validLen = b64.indexOf('=');
        if (validLen === -1) validLen = len;
        var placeHoldersLen = validLen === len ? 0 : 4 - (validLen % 4);
        return [validLen, placeHoldersLen];
    }
    function _byteLength(validLen, placeHoldersLen) {
        return ((validLen + placeHoldersLen) * 3 / 4) - placeHoldersLen;
    }
    function toByteArray(b64) {
        var lens = getLens(b64);
        var validLen = lens[0];
        var placeHoldersLen = lens[1];
        var arr = new Arr(_byteLength(validLen, placeHoldersLen));
        var curByte = 0;
        var len = placeHoldersLen > 0 ? validLen - 4 : validLen;
        var i, tmp;
        for (i = 0; i < len; i += 4) {
            tmp = (revLookup[b64.charCodeAt(i)] << 18) |
                (revLookup[b64.charCodeAt(i + 1)] << 12) |
                (revLookup[b64.charCodeAt(i + 2)] << 6) |
                revLookup[b64.charCodeAt(i + 3)];
            arr[curByte++] = (tmp >> 16) & 0xFF;
            arr[curByte++] = (tmp >> 8) & 0xFF;
            arr[curByte++] = tmp & 0xFF;
        }
        if (placeHoldersLen === 2) {
            tmp = (revLookup[b64.charCodeAt(i)] << 2) | (revLookup[b64.charCodeAt(i + 1)] >> 4);
            arr[curByte++] = tmp & 0xFF;
        }
        if (placeHoldersLen === 1) {
            tmp = (revLookup[b64.charCodeAt(i)] << 10) |
                (revLookup[b64.charCodeAt(i + 1)] << 4) |
                (revLookup[b64.charCodeAt(i + 2)] >> 2);
            arr[curByte++] = (tmp >> 8) & 0xFF;
            arr[curByte++] = tmp & 0xFF;
        }
        return arr;
    }

    // ── Tiktoken class (from js-tiktoken src, MIT) ─────────────────
    function escapeRegex(str) { return str.replace(/[\\^$*+?.()|[\]{}]/g, '\\$&'); }

    function specialTokenRegex(tokens) {
        return new RegExp(tokens.map(escapeRegex).join('|'), 'g');
    }

    function bytePairMerge(piece, ranks) {
        var parts = [];
        for (var k = 0; k < piece.length; k++) parts.push({ start: k, end: k + 1 });
        while (parts.length > 1) {
            var minRank = null;
            for (var i = 0; i < parts.length - 1; i++) {
                var slice = piece.slice(parts[i].start, parts[i + 1].end);
                var rank = ranks.get(slice.join(','));
                if (rank == null) continue;
                if (minRank == null || rank < minRank[0]) minRank = [rank, i];
            }
            if (minRank != null) {
                var i = minRank[1];
                parts[i] = { start: parts[i].start, end: parts[i + 1].end };
                parts.splice(i + 1, 1);
            } else break;
        }
        return parts;
    }
    function bytePairEncode(piece, ranks) {
        if (piece.length === 1) return [ranks.get(piece.join(','))];
        return bytePairMerge(piece, ranks)
            .map(function (p) { return ranks.get(piece.slice(p.start, p.end).join(',')); })
            .filter(function (x) { return x != null; });
    }

    function Tiktoken(ranks, extendedSpecialTokens) {
        this.patStr = ranks.pat_str;
        this.textEncoder = new TextEncoder();
        this.textDecoder = new TextDecoder('utf-8');
        this.rankMap = new Map();
        this.textMap = new Map();
        var lines = ranks.bpe_ranks.split('\n');
        for (var li = 0; li < lines.length; li++) {
            var line = lines[li];
            if (!line) continue;
            var parts = line.split(' ');
            var offset = parseInt(parts[1], 10);
            for (var ti = 2; ti < parts.length; ti++) {
                var token = parts[ti];
                var rank = offset + (ti - 2);
                var bytes = toByteArray(token);
                this.rankMap.set(bytes.join(','), rank);
                this.textMap.set(rank, bytes);
            }
        }
        this.specialTokens = Object.assign({}, ranks.special_tokens, extendedSpecialTokens || {});
        var inv = {};
        var self = this;
        Object.keys(this.specialTokens).forEach(function (text) {
            inv[self.specialTokens[text]] = self.textEncoder.encode(text);
        });
        this.inverseSpecialTokens = inv;
    }
    Tiktoken.prototype.specialTokenRegex = specialTokenRegex;

    Tiktoken.prototype.encode = function (text, allowedSpecial, disallowedSpecial) {
        allowedSpecial = allowedSpecial || [];
        disallowedSpecial = disallowedSpecial == null ? 'all' : disallowedSpecial;
        var regexes = new RegExp(this.patStr, 'ug');
        var specialRegex = specialTokenRegex(Object.keys(this.specialTokens));
        var ret = [];
        var allowedSpecialSet = new Set(allowedSpecial === 'all' ? Object.keys(this.specialTokens) : allowedSpecial);
        var disallowedSpecialSet = new Set(disallowedSpecial === 'all'
            ? Object.keys(this.specialTokens).filter(function (x) { return !allowedSpecialSet.has(x); })
            : disallowedSpecial);
        if (disallowedSpecialSet.size > 0) {
            var disallowedSpecialRegex = specialTokenRegex(Array.from(disallowedSpecialSet));
            var specialMatch = text.match(disallowedSpecialRegex);
            if (specialMatch != null) {
                throw new Error('The text contains a special token that is not allowed: ' + specialMatch[0]);
            }
        }
        var start = 0;
        while (true) {
            var nextSpecial = null;
            var startFind = start;
            while (true) {
                specialRegex.lastIndex = startFind;
                nextSpecial = specialRegex.exec(text);
                if (nextSpecial == null || allowedSpecialSet.has(nextSpecial[0])) break;
                startFind = nextSpecial.index + 1;
            }
            var end = nextSpecial ? nextSpecial.index : text.length;
            var segment = text.substring(start, end);
            var matches = segment.matchAll(regexes);
            for (var m of matches) {
                var piece = this.textEncoder.encode(m[0]);
                var tok = this.rankMap.get(piece.join(','));
                if (tok != null) ret.push(tok);
                else { var enc = bytePairEncode(piece, this.rankMap); for (var e = 0; e < enc.length; e++) ret.push(enc[e]); }
            }
            if (nextSpecial == null) break;
            ret.push(this.specialTokens[nextSpecial[0]]);
            start = nextSpecial.index + nextSpecial[0].length;
        }
        return ret;
    };

    Tiktoken.prototype.decode = function (tokens) {
        var res = [];
        var length = 0;
        for (var i = 0; i < tokens.length; ++i) {
            var token = tokens[i];
            var bytes = this.textMap.get(token) || this.inverseSpecialTokens[token];
            if (bytes != null) { res.push(bytes); length += bytes.length; }
        }
        var merged = new Uint8Array(length);
        var off = 0;
        for (var b = 0; b < res.length; b++) { merged.set(res[b], off); off += res[b].length; }
        return this.textDecoder.decode(merged);
    };

    // ── Lazy rank loader ───────────────────────────────────────────
    var encoderPromise = null;
    var RANKS_URL = './lib/tiktoken/ranks/o200k_base.js';

    function loadRanksScript(url) {
        return new Promise(function (resolve, reject) {
            var s = document.createElement('script');
            s.src = url;
            s.async = true;
            s.onload = function () { resolve(); };
            s.onerror = function () { reject(new Error('Failed to load tokenizer ranks: ' + url)); };
            document.head.appendChild(s);
        });
    }

    function getEncoder() {
        if (!encoderPromise) {
            encoderPromise = loadRanksScript(RANKS_URL).then(function () {
                var ranks = window.__TIKTOKEN_O200K;
                if (!ranks) throw new Error('Tokenizer ranks did not load.');
                return new Tiktoken(ranks);
            });
        }
        return encoderPromise;
    }

    window.TiktokenLib = {
        tokenizeWithText: function (text) {
            return getEncoder().then(function (enc) {
                var tokens = enc.encode(text, 'all');
                var pieces = tokens.map(function (t) { return enc.decode([t]); });
                return { tokens: tokens, pieces: pieces };
            });
        },
    };
})();
