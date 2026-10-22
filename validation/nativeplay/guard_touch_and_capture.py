#!/usr/bin/env python3
"""Strict source guard for LiquidAss's frozen UIKit touch/capture semantics.

Run: python3 guard_touch_and_capture.py <repository-root>
The argument may be the repository root or its stage/ directory.
This is a source-only check: it never invokes Xcode, a simulator, or Metal.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

FREEZE_FILE = Path(__file__).with_name("frozen_touch_semantics.json")
SOURCE_PATHS = (
    "stage/validation/nativeplay/OwnedTouchRuntimeProbe.mm",
    "stage/Shared/LGLocalButtonMaterialView.mm",
    "stage/Shared/LGLocalButtonMaterialView.h",
    "stage/validation/nativeplay/LGDesignedLightGPUCapture.h",
)
class GuardFailure(Exception):
    pass


def mask_noncode(text: str) -> str:
    """Blank comments and quoted literals while preserving offsets/newlines."""
    out = list(text)
    i, n = 0, len(text)
    state = "code"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                out[i] = out[i + 1] = " "
                i += 2
                state = "line"
                continue
            if c == "/" and nxt == "*":
                out[i] = out[i + 1] = " "
                i += 2
                state = "block"
                continue
            if c == '"':
                out[i] = " "
                i += 1
                state = "string"
                continue
            if c == "'":
                out[i] = " "
                i += 1
                state = "char"
                continue
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = "code"
            else:
                out[i] = " "
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                out[i] = out[i + 1] = " "
                i += 2
                state = "code"
            else:
                if c != "\n":
                    out[i] = " "
                i += 1
            continue
        # String/character literal; escaped delimiters do not end the literal.
        if c == "\\":
            if c != "\n":
                out[i] = " "
            if i + 1 < n:
                if text[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
            else:
                i += 1
            continue
        if (state == "string" and c == '"') or (state == "char" and c == "'"):
            out[i] = " "
            i += 1
            state = "code"
            continue
        if c != "\n":
            out[i] = " "
        i += 1
    return "".join(out)


def canonical_signature(signature: str) -> str:
    return re.sub(r"\s+", " ", mask_noncode(signature).strip())


def _selector_from_signature(signature: str) -> str:
    masked = mask_noncode(signature)
    lead = re.match(r"\s*([+-])\s*\(", masked)
    if not lead:
        raise GuardFailure("cannot parse Objective-C method signature")
    i = lead.end()
    depth = 1
    while i < len(masked) and depth:
        if masked[i] == "(":
            depth += 1
        elif masked[i] == ")":
            depth -= 1
        i += 1
    if depth:
        raise GuardFailure("unclosed return type in Objective-C signature")
    rest = masked[i:]
    first = re.search(r"[A-Za-z_][A-Za-z_0-9]*", rest)
    if not first:
        raise GuardFailure("missing Objective-C selector")
    sign = lead.group(1)
    pieces: List[str] = []
    paren = angle = bracket = 0
    for j, ch in enumerate(rest):
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren = max(0, paren - 1)
        elif ch == "<":
            angle += 1
        elif ch == ">":
            angle = max(0, angle - 1)
        elif ch == "[":
            bracket += 1
        elif ch == "]":
            bracket = max(0, bracket - 1)
        elif ch == ":" and paren == 0 and angle == 0 and bracket == 0:
            before = rest[:j]
            name = re.search(r"([A-Za-z_][A-Za-z_0-9]*)\s*$", before)
            if name:
                pieces.append(name.group(1) + ":")
    return sign + ("".join(pieces) if pieces else first.group(0))


class MethodDef:
    def __init__(self, selector: str, signature: str, start: int, open_brace: int, close_brace: int):
        self.selector = selector
        self.signature = signature
        self.start = start
        self.open_brace = open_brace
        self.close_brace = close_brace

    @property
    def body_slice(self) -> slice:
        return slice(self.open_brace, self.close_brace + 1)


def extract_objc_methods(source: str) -> List[MethodDef]:
    """Parse method definitions with string/comment-safe balanced delimiters."""
    code = mask_noncode(source)
    found: List[MethodDef] = []
    start_re = re.compile(r"(?m)^[ \t]*([+-])\s*\(")
    for match in start_re.finditer(code):
        start = match.start(1)
        i = match.end()
        paren, bracket, angle = 1, 0, 0  # opening return-type '(' is in match
        body_open = None
        declaration = False
        while i < len(code):
            ch = code[i]
            if ch == "(":
                paren += 1
            elif ch == ")":
                paren = max(0, paren - 1)
            elif ch == "[":
                bracket += 1
            elif ch == "]":
                bracket = max(0, bracket - 1)
            elif ch == "<":
                angle += 1
            elif ch == ">":
                angle = max(0, angle - 1)
            elif ch == "{" and paren == 0 and bracket == 0 and angle == 0:
                body_open = i
                break
            elif ch == ";" and paren == 0 and bracket == 0 and angle == 0:
                declaration = True
                break
            i += 1
        if declaration or body_open is None:
            continue
        depth = 1
        j = body_open + 1
        while j < len(code) and depth:
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
            j += 1
        if depth:
            raise GuardFailure("unterminated Objective-C method body")
        close_brace = j - 1
        signature = canonical_signature(source[start:body_open])
        selector = _selector_from_signature(signature)
        found.append(MethodDef(selector, signature, start, body_open, close_brace))
    return found


def unique_method(source: str, selector: str, label: str) -> Tuple[MethodDef, str]:
    matches = [m for m in extract_objc_methods(source) if m.selector == selector]
    if len(matches) != 1:
        raise GuardFailure(f"{label}: expected one definition of {selector}, found {len(matches)}")
    method = matches[0]
    return method, source[method.body_slice]


def extract_c_function(source: str, name: str, label: str) -> str:
    code = mask_noncode(source)
    match = re.search(r"\b" + re.escape(name) + r"\s*\(", code)
    if not match:
        raise GuardFailure(f"{label}: missing function {name}")
    i = code.find("(", match.start()) + 1
    depth = 1
    while i < len(code) and depth:
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
        i += 1
    if depth:
        raise GuardFailure(f"{label}: malformed function declaration {name}")
    while i < len(code) and code[i] not in "{;":
        i += 1
    if i >= len(code) or code[i] != "{":
        raise GuardFailure(f"{label}: missing body for {name}")
    start, depth = i, 1
    i += 1
    while i < len(code) and depth:
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
        i += 1
    if depth:
        raise GuardFailure(f"{label}: unterminated function body {name}")
    return source[start:i]


def _one_line(text: str) -> str:
    return re.sub(r"\s+", " ", mask_noncode(text).strip())


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", mask_noncode(text))


def string_literals(text: str) -> List[str]:
    """Read non-comment quoted strings, including Objective-C @"..." literals."""
    values: List[str] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i + 2)
            i = n if end < 0 else end + 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text[i] in "\"'":
            quote = text[i]
            i += 1
            chars: List[str] = []
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    chars.append(text[i + 1])
                    i += 2
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    chars.append(text[i])
                    i += 1
            if quote == '"':
                values.append("".join(chars))
            continue
        i += 1
    return values


def _if_assignments(body: str, variable: str) -> List[Tuple[str, str]]:
    """Return (string RHS, compact condition) for simple `if (...) n=@"..."` branches."""
    code = mask_noncode(body)
    branches: List[Tuple[str, str]] = []
    for match in re.finditer(r"\bif\s*\(", code):
        opening = code.find("(", match.start())
        depth, i = 1, opening + 1
        while i < len(code) and depth:
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
            i += 1
        if depth:
            continue
        closing = i - 1
        assign = re.match(r"\s*" + re.escape(variable) + r"\s*=", code[closing + 1:])
        if not assign:
            continue
        rhs_start = closing + 1 + assign.end()
        literal = re.match(r'\s*@?"((?:\\.|[^"\\])*)"', body[rhs_start:])
        if literal:
            value = re.sub(r"\\(.)", r"\1", literal.group(1))
            condition = re.sub(r"\s+", "", code[opening + 1:closing])
            branches.append((value, condition))
    return branches


def _source_path(repo_root: Path, relative: str) -> Path:
    rel = Path(relative)
    candidates = [repo_root / rel]
    if relative.startswith("stage/"):
        candidates.append(repo_root / relative[len("stage/"):])
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise GuardFailure(f"missing source file {relative} under {repo_root}")


def _load_sources(repo_root: Path, frozen: dict) -> Dict[str, str]:
    paths = set(SOURCE_PATHS)
    paths.update(item["file"] for item in frozen["methods"])
    sources: Dict[str, str] = {}
    for relative in sorted(paths):
        path = _source_path(repo_root, relative)
        try:
            sources[relative] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise GuardFailure(f"cannot read {path}: {exc}") from exc
    return sources


def _freeze_check(sources: Dict[str, str], frozen: dict) -> List[str]:
    defs: Dict[str, List[MethodDef]] = {}
    errors: List[str] = []
    for relative in {item["file"] for item in frozen["methods"]}:
        defs[relative] = extract_objc_methods(sources[relative])
    by_file: Dict[str, List[dict]] = {}
    for item in frozen["methods"]:
        by_file.setdefault(item["file"], []).append(item)
    for relative, expected_list in by_file.items():
        actual = defs[relative]
        positions: List[int] = []
        for expected in expected_list:
            found = [m for m in actual if m.selector == expected["selector"]]
            if len(found) != 1:
                errors.append(f"FROZEN {relative} {expected['selector']}: expected exactly one method definition, found {len(found)}")
                continue
            method = found[0]
            positions.append(method.start)
            if method.signature != expected["signature"]:
                errors.append(f"FROZEN {relative} {expected['selector']}: signature drift\n  expected: {expected['signature']}\n  actual:   {method.signature}")
            digest = hashlib.sha256(sources[relative][method.body_slice].encode("utf-8")).hexdigest()
            if digest != expected["body_sha256"]:
                errors.append(f"FROZEN {relative} {expected['selector']}: complete method-body SHA-256 drift (expected {expected['body_sha256']}, got {digest})")
        if len(positions) == len(expected_list) and positions != sorted(positions):
            errors.append(f"FROZEN {relative}: frozen method order changed")
    return errors


def _methods_by_selector(source: str) -> Dict[str, List[Tuple[MethodDef, str]]]:
    result: Dict[str, List[Tuple[MethodDef, str]]] = {}
    for method in extract_objc_methods(source):
        result.setdefault(method.selector, []).append((method, source[method.body_slice]))
    return result


def _single_body(methods: Dict[str, List[Tuple[MethodDef, str]]], selector: str, label: str) -> str:
    matches = methods.get(selector, [])
    if len(matches) != 1:
        raise GuardFailure(f"{label}: expected one method {selector}, found {len(matches)}")
    return matches[0][1]


def _check_no_subclasses(sources: Dict[str, str]) -> List[str]:
    # Scope exactly the four reviewed source files; do not infer from unrelated
    # validation fixtures elsewhere in a larger repository.
    errors: List[str] = []
    for relative, source in sources.items():
        code = mask_noncode(source)
        if re.search(r"@interface\s+[A-Za-z_][A-Za-z_0-9]*\s*:\s*LGLocalButtonMaterialView\b", code):
            errors.append(f"SUBCLASS forbidden: {relative} subclasses LGLocalButtonMaterialView")
    return errors


def _check_drawable_capture(sources: Dict[str, str]) -> List[str]:
    errors: List[str] = []
    try:
        local = sources["stage/Shared/LGLocalButtonMaterialView.mm"]
        methods = _methods_by_selector(local)
        init_body = _single_body(methods,
            "-initWithFrame:targetView:sourceProvider:allowApproximateSource:explicitOptIn:", "renderer")
        draw = _single_body(methods, "-drawInMTKView:", "renderer")
        if not re.search(r"\bframebufferOnly\s*=\s*YES\b", mask_noncode(init_body)):
            errors.append("DRAW framebufferOnly must remain YES on the renderer")
        if re.search(r"\bframebufferOnly\s*=\s*NO\b", mask_noncode(local)):
            errors.append("DRAW renderer must never disable framebufferOnly")

        draw_code = mask_noncode(draw)
        uniform = re.search(r"\[\s*encoder\s+setFragmentBytes\s*:\s*&\s*uniforms\b", draw_code)
        calls = list(re.finditer(r"\bencodeForCommand\s*:\s*command\b", draw_code))
        if len(calls) != 1:
            errors.append(f"WIRING expected exactly one auxiliary encodeForCommand:command call, found {len(calls)}")
        if not uniform:
            errors.append("WIRING primary drawable must set fragment bytes from &uniforms")
        if len(calls) == 1 and uniform and uniform.start() >= calls[0].start():
            errors.append("WIRING primary setFragmentBytes:&uniforms must precede auxiliary capture encoding")
        if len(calls) == 1:
            at = calls[0].start()
            open_bracket = draw_code.rfind("[", 0, at)
            depth, close_bracket = 0, None
            for i in range(open_bracket, len(draw_code)):
                if draw_code[i] == "[":
                    depth += 1
                elif draw_code[i] == "]":
                    depth -= 1
                    if depth == 0:
                        close_bracket = i
                        break
            call = draw_code[open_bracket:close_bracket + 1] if open_bracket >= 0 and close_bracket is not None else ""
            call_compact = re.sub(r"\s+", "", call)
            required = (
                "encodeForCommand:command", "device:self.device", "pipeline:self.localPipeline",
                "sampler:self.localSampler", "drawable:drawable.texture", "source:frame.texture",
                "uniforms:uniforms", "state:submittedState", "contract:frame.contract", "serial:serial",
            )
            for token in required:
                if token not in call_compact:
                    errors.append(f"WIRING auxiliary call lost exact primary input {token}")
            order_tokens = ((r"\[\s*encoder\s+endEncoding\s*\]", "primary encoder endEncoding"),
                            (r"\[\s*command\s+presentDrawable\s*:\s*drawable\s*\]", "primary drawable present"),
                            (r"\[\s*command\s+commit\s*\]", "primary command commit"))
            order_positions = []
            for pattern, label in order_tokens:
                found = re.search(pattern, draw_code)
                if not found:
                    errors.append(f"WIRING missing {label}")
                    order_positions.append(-1)
                else:
                    order_positions.append(found.start())
            if order_positions[0] >= 0 and order_positions[0] > calls[0].start():
                errors.append("WIRING auxiliary pass must follow primary encoder endEncoding")
            for pos, label in ((order_positions[1], "primary drawable present"), (order_positions[2], "primary command commit")):
                if pos >= 0 and pos < calls[0].start():
                    errors.append(f"WIRING {label} must follow auxiliary encoding")
            if order_positions[1] >= 0 and order_positions[2] >= 0 and order_positions[1] >= order_positions[2]:
                errors.append("WIRING primary presentDrawable must precede commit")
            if not re.search(r"\[\s*encoder\s+setFragmentTexture\s*:\s*frame\.texture\s+atIndex\s*:\s*0\s*\]", draw_code):
                errors.append("WIRING primary drawable pass must sample the exact source frame")
    except (GuardFailure, KeyError) as exc:
        errors.append(str(exc))
    return errors


def _check_capture_helper(sources: Dict[str, str]) -> List[str]:
    errors: List[str] = []
    try:
        header = sources["stage/validation/nativeplay/LGDesignedLightGPUCapture.h"]
        helper_methods = _methods_by_selector(header)
        candidate = _single_body(helper_methods, "-candidateAndClaim:", "capture helper")
        encode = _single_body(helper_methods,
            "-encodeForCommand:device:pipeline:sampler:drawable:source:uniforms:state:contract:serial:", "capture helper")
        cencode = extract_c_function(header, "LGDLEncodePass", "capture helper")
        cbody = _compact(cencode)
        b = _compact(candidate)
        e = _compact(encode)

        if "if(!s.eligible)returnnil;" not in b:
            errors.append("STATE candidates must require eligible optical state")
        if "self.hadContact=YES;" not in b or "BOOLcontact=s.tracking&&s.touchValid&&isfinite(s.pressure)&&s.pressure>0.0f&&(s.phase==LGOpticalTrackingInside||s.phase==LGOpticalTrackingOutside)" not in b:
            errors.append("STATE contact history/inside-outside tracking semantics weakened")
        if not re.search(r"self\.claimedStates\.count\s*>=\s*4", mask_noncode(candidate)):
            errors.append("STATE capture suite must stop at four distinct states")
        add = b.find("[self.claimedStatesaddObject:n]")
        guard = b.find("self.claimedStates.count>=4")
        if add < 0 or guard < 0 or guard > add:
            errors.append("STATE four-state ceiling must be checked before claiming a state")

        assignments = _if_assignments(candidate, "n")
        branches: Dict[str, List[str]] = {}
        for state_name, condition in assignments:
            branches.setdefault(state_name, []).append(condition)
        if set(branches) != {"idle", "left", "right", "release"} or any(len(v) != 1 for v in branches.values()):
            errors.append("STATE each of idle/left/right/release must be assigned by one actual if branch")
        else:
            required = {
                "idle": ("!self.hadContact", "!s.tracking", "!s.touchValid", "s.phase==LGOpticalIdle", "s.pressure==0.0f", "s.target==0.0f"),
                "left": ("s.tracking", "s.touchValid", "isfinite(s.pressure)", "s.pressure>=0.9995f", "isfinite(s.touchX)", "s.touchX<=0.1f", "isfinite(s.touchY)", "s.touchY>=0.0f", "s.touchY<=1.0f", "s.phase==LGOpticalTrackingInside"),
                "right": ("s.tracking", "s.touchValid", "isfinite(s.pressure)", "s.pressure>=0.9995f", "isfinite(s.touchX)", "s.touchX>=0.9f", "s.touchX<=1.0f", "isfinite(s.touchY)", "s.touchY>=0.0f", "s.touchY<=1.0f", "s.phase==LGOpticalTrackingInside"),
                "release": ("self.hadContact", "!s.tracking", "s.pressure==0.0f", "s.target==0.0f", "s.phase==LGOpticalIdle", "s.phase==LGOpticalReleasing"),
            }
            for state_name, tokens in required.items():
                condition = branches[state_name][0]
                if any(token not in condition for token in tokens):
                    errors.append(f"STATE {state_name} branch no longer proves its frozen inside/idle/release conditions")
            release_condition = branches["release"][0]
            if "s.phase==LGOpticalIdle||s.phase==LGOpticalReleasing" not in release_condition:
                errors.append("STATE release branch must accept only idle or releasing phase")

        for token in (
            "uoff=uniforms,uon=uniforms", "uoff.fresnelGlareStrength=0.0f",
            "uon.fresnelGlareStrength=1.0f",
            "LGDLEncodePass(command,pipeline,sampler,source,off,uoff)",
            "LGDLEncodePass(command,pipeline,sampler,source,on,uon)",
            "r.offTexture=off", "r.onTexture=on",
        ):
            if token not in e:
                errors.append(f"HELPER capture must preserve auxiliary-only same-input variant: missing {token}")
        if cbody.count("[esetRenderPipelineState:p]") != 1:
            errors.append("HELPER auxiliary encoder must use the passed pipeline")
        if cbody.count("[esetFragmentTexture:src") < 2 or "[esetFragmentBytes:&u" not in cbody:
            errors.append("HELPER auxiliary encoder must bind passed source and uniforms")

        code_header = mask_noncode(header)
        if re.search(r"\bLGLocalButtonTextureFrame\b|\bsourceFrame\b", code_header):
            errors.append("HELPER must not refer to/retain a sourceFrame lease")
        record_match = re.search(r"@interface\s+LGDesignedLightCaptureRecord\s*\(\s*\)(.*?)@end", code_header, re.S)
        if not record_match or re.search(r"@property[^;]*\bsource\w*\b", record_match.group(1)):
            errors.append("HELPER capture record may retain only its auxiliary textures, not source/frame")
        encode_code = mask_noncode(encode)
        if re.search(r"\bgetBytes\b|\bLGDLReadSharedBGRA\s*\(|\bcontents\b", encode_code):
            errors.append("HELPER must not read back primary drawable or any capture texture during encoding")
        if re.search(r"\bsourceFrame\b|\bLGLocalButtonTextureFrame\b|\b(?:record|r)\s*\.\s*source\w*\s*=", encode_code):
            errors.append("HELPER must not retain the source texture/frame in its capture record")
    except (GuardFailure, KeyError) as exc:
        errors.append(str(exc))
    return errors


def run_guard(repo_root: Path) -> List[str]:
    if not FREEZE_FILE.is_file():
        return [f"missing freeze manifest {FREEZE_FILE}"]
    try:
        frozen = json.loads(FREEZE_FILE.read_text(encoding="utf-8"))
        if frozen.get("schema_version") != 1 or not isinstance(frozen.get("methods"), list):
            raise GuardFailure("invalid frozen_touch_semantics.json schema")
        sources = _load_sources(repo_root, frozen)
    except (OSError, json.JSONDecodeError, GuardFailure) as exc:
        return [str(exc)]
    errors = _freeze_check(sources, frozen)
    errors.extend(_check_no_subclasses(sources))
    errors.extend(_check_drawable_capture(sources))
    errors.extend(_check_capture_helper(sources))
    return errors


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <repository-root>", file=sys.stderr)
        return 2
    root = Path(argv[1]).expanduser().resolve()
    if not root.is_dir():
        print(f"FAIL: repository root is not a directory: {root}", file=sys.stderr)
        return 2
    errors = run_guard(root)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: LiquidAss frozen UIKit touch semantics and drawable-to-capture source guard ({root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
