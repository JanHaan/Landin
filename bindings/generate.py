#!/usr/bin/env python3
"""Generate deterministic Landin/C bindings from a Clang JSON AST."""

from __future__ import annotations

import argparse
import ast as python_ast
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from typing import Any, Iterable, Mapping, Sequence

SCHEMA_VERSION = 1
SUPPORTED_TARGET = "x86_64-pc-linux-gnu"
GENERATOR_ID = "landin-bindings/1"
OUTPUT_NAMES = ("bindings.ldn", "adapters.c", "exports.h", "bindings.json")

C_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
LANDIN_IDENTIFIER = re.compile(r"[a-z][a-z0-9_]*\Z")
DEFINE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:=.*)?\Z", re.DOTALL)
# spec.md [1760]'s keyword production, independently checked by test.py.
LANDIN_KEYWORDS = {
    "addr", "alignof", "and", "any", "atom", "dec", "else", "elsif", "end",
    "escaping", "extern", "fail", "false", "fixed", "from", "if", "import",
    "in", "inc", "inout", "mut", "none", "not", "or", "ptr", "public",
    "return", "sink", "sizeof", "struct", "then", "true", "try", "type",
    "when", "zeroed",
}
# Contextual syntax and builtin names also make poor generated identifiers.
LANDIN_AVOID = LANDIN_KEYWORDS | {
    "as", "assembler", "begin", "bool", "break", "caller", "compiler", "concept", "consume", "continue",
    "defer", "for", "layout", "link", "linker", "loop", "match", "packed", "range",
    "symbol", "text", "unchecked", "variant", "while",
}

BUILTIN_CANONICAL = {
    "char": "char", "signed char": "signed char", "unsigned char": "unsigned char",
    "short": "short", "short int": "short", "signed short": "short",
    "signed short int": "short", "unsigned short": "unsigned short",
    "unsigned short int": "unsigned short", "int": "int", "signed": "int",
    "signed int": "int", "unsigned": "unsigned int", "unsigned int": "unsigned int",
    "long": "long", "long int": "long", "signed long": "long",
    "signed long int": "long", "unsigned long": "unsigned long",
    "unsigned long int": "unsigned long", "long long": "long long",
    "long long int": "long long", "signed long long": "long long",
    "signed long long int": "long long", "unsigned long long": "unsigned long long",
    "unsigned long long int": "unsigned long long", "float": "float",
    "double": "double", "_Bool": "_Bool", "bool": "_Bool", "void": "void",
}
BUILTIN_LANDIN = {
    "char": "c.c_char", "signed char": "c.c_schar", "unsigned char": "c.c_uchar",
    "short": "c.c_short", "unsigned short": "c.c_ushort", "int": "c.c_int",
    "unsigned int": "c.c_uint", "long": "c.c_long", "unsigned long": "c.c_ulong",
    "long long": "c.c_longlong", "unsigned long long": "c.c_ulonglong",
    "float": "c.c_float", "double": "c.c_double", "_Bool": "c.c_bool",
}
BUILTIN_LAYOUT = {
    "char": (1, 1), "signed char": (1, 1), "unsigned char": (1, 1),
    "short": (2, 2), "unsigned short": (2, 2), "int": (4, 4),
    "unsigned int": (4, 4), "long": (8, 8), "unsigned long": (8, 8),
    "long long": (8, 8), "unsigned long long": (8, 8), "float": (4, 4),
    "double": (8, 8), "_Bool": (1, 1),
}
PROMOTED_TYPES = {
    "c_int": "int", "c_uint": "unsigned int", "c_long": "long",
    "c_ulong": "unsigned long", "c_longlong": "long long",
    "c_ulonglong": "unsigned long long", "c_double": "double",
    "pointer": "void *",
}


class BindingError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BindingError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def sanitize_landin(name: str) -> str:
    candidate = re.sub(r"[^a-z0-9_]", "_", name.lower())
    if not candidate or not candidate[0].islower():
        candidate = "c_" + candidate
    if candidate == "_" or candidate in LANDIN_AVOID:
        candidate = "c_" + candidate
    require(bool(LANDIN_IDENTIFIER.fullmatch(candidate)), f"cannot form a Landin identifier from {name!r}")
    return candidate


def require_landin_name(name: Any, context: str) -> str:
    require(isinstance(name, str) and bool(LANDIN_IDENTIFIER.fullmatch(name)),
            f"{context}: landin_name must be an identifier")
    require(name != "_" and name not in LANDIN_AVOID,
            f"{context}: landin_name {name!r} is reserved")
    return name


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def split_top_level(text: str, delimiter: str = ",") -> list[str]:
    pieces: list[str] = []
    start = 0
    paren = bracket = 0
    for index, char in enumerate(text):
        if char == "(":
            paren += 1
        elif char == ")":
            paren -= 1
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket -= 1
        elif char == delimiter and paren == 0 and bracket == 0:
            pieces.append(text[start:index].strip())
            start = index + 1
    pieces.append(text[start:].strip())
    return pieces


def split_function_spelling(text: str) -> tuple[str, str] | None:
    # Only a simple result followed by one complete parameter list. In
    # particular int (*(void))(int) is NOT an int-returning function.
    start = text.find("(")
    if start <= 0:
        return None
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                if index != len(text) - 1 or text[start + 1:].lstrip().startswith("*"):
                    return None
                return text[:start].strip(), text[start + 1:index].strip()
    return None


@dataclasses.dataclass(frozen=True)
class CType:
    kind: str
    spelling: str
    name: str = ""
    const: bool = False
    child: "CType | None" = None
    count: int = 0
    result: "CType | None" = None
    parameters: tuple["CType", ...] = ()
    variadic: bool = False
    old_style: bool = False
    declaration_id: str = ""  # Private identity; never serialized.


@dataclasses.dataclass(frozen=True)
class HeaderInput:
    logical: str
    path: pathlib.Path
    digest: str
    content: bytes


@dataclasses.dataclass
class RecordInfo:
    node: dict[str, Any]
    identity: str
    tag: str
    typedef_names: list[str] = dataclasses.field(default_factory=list)

    @property
    def complete(self) -> bool:
        return bool(self.node.get("completeDefinition"))

    @property
    def union(self) -> bool:
        return self.node.get("tagUsed") == "union"

    @property
    def c_name(self) -> str:
        if self.typedef_names:
            return self.typedef_names[0]
        if self.tag:
            return f"{self.node.get('tagUsed', 'struct')} {self.tag}"
        return ""

    @property
    def display_name(self) -> str:
        return self.typedef_names[0] if self.typedef_names else self.tag

    @property
    def fields(self) -> list[dict[str, Any]]:
        return [item for item in self.node.get("inner", []) if item.get("kind") == "FieldDecl"]


@dataclasses.dataclass
class EnumInfo:
    node: dict[str, Any]
    identity: str
    tag: str
    typedef_names: list[str] = dataclasses.field(default_factory=list)
    compatible_type: str | None = None

    @property
    def display_name(self) -> str:
        if self.typedef_names:
            return self.typedef_names[0]
        return self.tag

    @property
    def c_name(self) -> str:
        if self.typedef_names:
            return self.typedef_names[0]
        if self.tag:
            return f"enum {self.tag}"
        return ""

    @property
    def constants(self) -> list[dict[str, Any]]:
        return [item for item in self.node.get("inner", []) if item.get("kind") == "EnumConstantDecl"]


class ASTModel:
    def __init__(self, root: Mapping[str, Any]) -> None:
        self.typedefs: dict[str, dict[str, Any]] = {}
        self.typedefs_by_id: dict[str, dict[str, Any]] = {}
        self.functions: dict[str, list[dict[str, Any]]] = defaultdict(list)
        self.variables: dict[str, list[dict[str, Any]]] = defaultdict(list)
        records_by_id: dict[str, RecordInfo] = {}
        enums_by_id: dict[str, EnumInfo] = {}
        nodes: list[dict[str, Any]] = []
        local_ids: set[str] = set()
        self.identifiers: set[str] = set()

        def walk(node: Any, inside_function: bool = False) -> None:
            if not isinstance(node, dict):
                return
            kind = node.get("kind")
            if isinstance(kind, str):
                nodes.append(node)
                if node.get("name"):
                    self.identifiers.add(node["name"])
                if inside_function and node.get("id"):
                    local_ids.add(node["id"])
            child_inside_function = inside_function or kind == "FunctionDecl"
            for child in node.get("inner", []):
                walk(child, child_inside_function)

        walk(root)
        for node in nodes:
            kind = node.get("kind")
            identity = node.get("id", "")
            if kind == "TypedefDecl" and identity and not node.get("isImplicit"):
                self.typedefs_by_id[identity] = node
            # A public policy is never a selector for a body/prototype scope.
            if identity in local_ids:
                continue
            if kind == "RecordDecl" and identity:
                current = records_by_id.get(identity)
                if current is None or (not current.complete and node.get("completeDefinition")):
                    records_by_id[identity] = RecordInfo(node, identity, node.get("name", ""))
            elif kind == "EnumDecl" and identity:
                enums_by_id.setdefault(identity, EnumInfo(node, identity, node.get("name", "")))
            elif kind == "TypedefDecl" and not node.get("isImplicit") and node.get("name"):
                self.typedefs[node["name"]] = node
                if identity:
                    self.typedefs_by_id[identity] = node
            elif kind == "FunctionDecl" and node.get("name") and not node.get("isImplicit"):
                self.functions[node["name"]].append(node)
            elif kind == "VarDecl" and node.get("name"):
                self.variables[node["name"]].append(node)

        for name, node in self.typedefs.items():
            target_id, target_kind = self._owned_tag(node)
            if target_kind == "RecordDecl" and target_id in records_by_id:
                records_by_id[target_id].typedef_names.append(name)
            elif target_kind == "EnumDecl" and target_id in enums_by_id:
                enums_by_id[target_id].typedef_names.append(name)

        self.records = list(records_by_id.values())
        self.enums = list(enums_by_id.values())
        self.records_by_tag = {record.tag: record for record in self.records if record.tag}
        self.enums_by_tag = {enum.tag: enum for enum in self.enums if enum.tag}
        self.records_by_typedef = {
            name: record for record in self.records for name in record.typedef_names
        }
        self.enums_by_typedef = {
            name: enum for enum in self.enums for name in enum.typedef_names
        }

    @staticmethod
    def _owned_tag(node: Mapping[str, Any]) -> tuple[str, str]:
        # Clang gives a forward typedef both an ownedTagDecl for the first
        # declaration and a nested RecordType/EnumType decl for the canonical
        # (usually complete) redeclaration. Prefer the latter.
        declarations: list[tuple[str, str]] = []
        owned: list[tuple[str, str]] = []

        def walk(value: Any) -> None:
            if not isinstance(value, dict):
                return
            declaration = value.get("decl")
            if isinstance(declaration, dict) and declaration.get("kind") in {"RecordDecl", "EnumDecl"}:
                declarations.append((declaration.get("id", ""), declaration.get("kind", "")))
            owned_declaration = value.get("ownedTagDecl")
            if isinstance(owned_declaration, dict):
                owned.append((owned_declaration.get("id", ""),
                              owned_declaration.get("kind", "")))
            # A typedef owns a tag only through its direct elaborated/tag type.
            # Do not descend through pointers, arrays, or function signatures:
            # tags mentioned there are dependencies, not aliases of the typedef.
            if value.get("kind") in {
                    "TypedefDecl", "TypedefType", "ElaboratedType", "RecordType", "EnumType",
                    "AttributedType", "ParenType"}:
                for child in value.get("inner", []):
                    walk(child)

        walk(node)
        candidates = declarations or owned
        return candidates[-1] if candidates else ("", "")

    def function(self, name: str) -> dict[str, Any] | None:
        values = self.functions.get(name, [])
        return values[-1] if values else None

    def variable(self, name: str) -> dict[str, Any] | None:
        values = self.variables.get(name, [])
        if not values:
            return None
        external = [value for value in values if value.get("storageClass") == "extern"]
        return external[-1] if external else values[-1]

    def record(self, selector: str) -> RecordInfo | None:
        if selector.startswith("struct "):
            return self.records_by_tag.get(selector[7:])
        if selector.startswith("union "):
            return self.records_by_tag.get(selector[6:])
        return self.records_by_typedef.get(selector) or self.records_by_tag.get(selector)

    def enum(self, selector: str) -> EnumInfo | None:
        if selector.startswith("enum "):
            return self.enums_by_tag.get(selector[5:])
        if selector.startswith("@"):
            first = selector[1:]
            matches = [value for value in self.enums
                       if value.constants and value.constants[0].get("name") == first]
            return matches[0] if len(matches) == 1 else None
        return self.enums_by_typedef.get(selector) or self.enums_by_tag.get(selector)


class TypeParser:
    def __init__(self, ast: ASTModel) -> None:
        self.ast = ast
        self._alias_cache: dict[str, CType] = {}
        self._alias_stack: set[str] = set()

    def from_info(self, info: Mapping[str, Any]) -> CType:
        spelling = info.get("qualType")
        require(isinstance(spelling, str), "Clang AST type is missing qualType")
        alias_id = info.get("typeAliasDeclId")
        if isinstance(alias_id, str) and alias_id in self.ast.typedefs_by_id:
            alias_name = self.ast.typedefs_by_id[alias_id]["name"]
            spelling_parts = spelling.split()
            unqualified_parts = [part for part in spelling_parts
                                 if part not in {"const", "restrict", "volatile"}]
            if unqualified_parts == [alias_name]:
                if "volatile" in spelling_parts:
                    return CType("unsupported", spelling,
                                 name="atomic or volatile qualified type")
                alias = self.alias(alias_name, alias_id)
                return dataclasses.replace(alias, const="const" in spelling_parts)
        if spelling in self.ast.typedefs:
            return self.alias(spelling)
        try:
            return self.parse(spelling)
        except BindingError:
            desugared = info.get("desugaredQualType")
            if isinstance(desugared, str) and desugared != spelling:
                return self.parse(desugared)
            raise

    def alias(self, name: str, identity: str | None = None) -> CType:
        node = (self.ast.typedefs_by_id[identity] if identity is not None
                else self.ast.typedefs[name])
        identity = node["id"]
        if identity in self._alias_cache:
            return CType("alias", name, name=name, child=self._alias_cache[identity],
                         declaration_id=identity)
        require(identity not in self._alias_stack, f"unsupported recursive typedef {name!r}")
        self._alias_stack.add(identity)
        type_nodes = [item for item in node.get("inner", [])
                      if item.get("kind", "").endswith("Type")]
        target = (self.from_node(type_nodes[0]) if type_nodes
                  else self.from_info(node["type"]))
        self._alias_stack.remove(identity)
        self._alias_cache[identity] = target
        return CType("alias", name, name=name, child=target, declaration_id=identity)

    @staticmethod
    def pointee_type(child: CType, spelling: str, const: bool = False) -> CType:
        target = child
        while target.kind == "alias" and target.child is not None:
            target = target.child
        if target.kind == "function":
            return dataclasses.replace(target, kind="callback", spelling=spelling, const=const)
        return CType("pointer", spelling, const=const, child=child)

    def from_node(self, node: Mapping[str, Any]) -> CType:
        """Use Clang's structural type nodes whenever the AST supplies them."""
        kind = node.get("kind", "")
        spelling = node.get("type", {}).get("qualType", "")
        children = node.get("inner", [])
        if kind in {"ElaboratedType", "ParenType"} and children:
            return self.from_node(children[0])
        if kind == "TypedefType":
            decl = node.get("decl", {})
            require(decl.get("id") in self.ast.typedefs_by_id,
                    f"unsupported unavailable typedef {decl.get('name')!r}")
            return self.alias(decl["name"], decl["id"])
        if kind in {"RecordType", "EnumType"}:
            declaration = node.get("decl", {})
            return CType("record" if kind == "RecordType" else "enum", spelling,
                         name=declaration.get("id", ""))
        if kind in {"FunctionProtoType", "FunctionNoProtoType"}:
            require(node.get("cc", "cdecl") == "cdecl",
                    f"unsupported calling convention {node.get('cc')!r}: {spelling}")
            require(children, f"Clang function type has no result: {spelling}")
            return CType("function", spelling, result=self.from_node(children[0]),
                         parameters=tuple(self.from_node(value) for value in children[1:]),
                         variadic=bool(node.get("variadic")),
                         old_style=kind == "FunctionNoProtoType")
        if kind == "PointerType" and children:
            return self.pointee_type(self.from_node(children[0]), spelling)
        if kind == "ConstantArrayType" and children:
            return CType("array", spelling, child=self.from_node(children[0]),
                         count=int(node["size"]))
        if kind == "QualType" and children:
            if "volatile" in node.get("qualifiers", ""):
                return CType("unsupported", spelling, name="atomic or volatile qualified type")
            return dataclasses.replace(self.from_node(children[0]),
                                       const="const" in node.get("qualifiers", ""))
        if kind == "AttributedType":
            return CType("unsupported", spelling, name="calling-convention or type attribute")
        return self.parse(spelling)

    def parse(self, spelling: str) -> CType:
        text = " ".join(spelling.strip().split())
        require(text, "Clang AST supplied an empty type")
        if "__attribute__" in text or "__vector" in text or "vector_size" in text:
            return CType("unsupported", text, name="vector or calling-convention attribute")
        if "_Complex" in text or "complex" in text:
            return CType("unsupported", text, name="complex type")
        if text in {"long double", "__float128", "_Float16", "__fp16"}:
            return CType("unsupported", text, name="extended or x87 floating type")
        if "__int128" in text:
            return CType("unsupported", text, name="128-bit integer type")
        if "va_list" in text:
            return CType("unsupported", text, name="va_list forwarding")
        if text.startswith("_Atomic") or " volatile" in f" {text}":
            return CType("unsupported", text, name="atomic or volatile qualified type")

        array = re.fullmatch(r"([^()\[\]]+)((?:\s*\[[^]]*\])+)", text)
        if array:
            # C's first bracket is the outer array, not its final bracket.
            result = self.parse(array.group(1))
            for extent in reversed(re.findall(r"\[([^]]*)\]", array.group(2))):
                extent = extent.strip()
                require(not extent or extent.isdigit(),
                        f"unsupported nonconstant array type {text!r}")
                result = CType("array", text, child=result,
                               count=int(extent) if extent else -1)
            return result

        callback = re.fullmatch(r"(.+?)\s*\(\*\s*(const\s*)?\)\((.*)\)", text)
        if callback:
            result = self.parse(callback.group(1))
            parameters, variadic, old_style = self._parse_parameters(callback.group(3))
            return CType("callback", text, const=bool(callback.group(2)), result=result,
                         parameters=parameters, variadic=variadic, old_style=old_style)

        pointer = re.fullmatch(
            r"(.+?) \*\s*((?:(?:const|restrict)\s*)*)", text)
        if pointer:
            pointee_text = pointer.group(1).strip()
            qualifiers = pointer.group(2).split()
            return self.pointee_type(self.parse(pointee_text), text, "const" in qualifiers)

        const = text.startswith("const ")
        if const:
            text = text[6:].strip()
        canonical = BUILTIN_CANONICAL.get(text)
        if canonical:
            return CType("builtin", spelling, name=canonical, const=const)
        if text.startswith("struct "):
            record = self.ast.record(text)
            if record:
                return CType("record", spelling, name=record.identity, const=const)
        if text.startswith("union "):
            record = self.ast.record(text)
            if record:
                return CType("record", spelling, name=record.identity, const=const)
        if text.startswith("enum "):
            enum = self.ast.enum(text)
            if enum:
                return CType("enum", spelling, name=enum.identity, const=const)
        if text in self.ast.typedefs:
            alias = self.alias(text)
            return dataclasses.replace(alias, const=const)
        if re.search(r"\((?:unnamed|anonymous)(?: (?:struct|union))? at ", text):
            return CType("unsupported", spelling, name="anonymous unaliased aggregate")
        function = split_function_spelling(text)
        if function:
            result = self.parse(function[0])
            parameters, variadic, old_style = self._parse_parameters(function[1])
            return CType("function", spelling, result=result, parameters=parameters,
                         variadic=variadic, old_style=old_style)
        return CType("unsupported", spelling, name="unrecognized Clang type")

    def _parse_parameters(self, text: str) -> tuple[tuple[CType, ...], bool, bool]:
        if text == "":
            return (), False, True
        if text == "void":
            return (), False, False
        parts = split_top_level(text)
        variadic = parts[-1] == "..."
        if variadic:
            parts.pop()
        return tuple(self.parse(part) for part in parts), variadic, False

@dataclasses.dataclass
class PolicyEntry:
    kind: str
    name: str
    landin_name: str
    raw: dict[str, Any]
    index: int

    @property
    def context(self) -> str:
        return f"policy declaration {self.index} ({self.kind} {self.name!r})"


@dataclasses.dataclass
class Policy:
    namespace: str
    abi: dict[str, str]
    entries: list[PolicyEntry]
    digest: str

    @classmethod
    def load(cls, path: pathlib.Path) -> "Policy":
        try:
            data_bytes = path.read_bytes()
        except OSError as error:
            raise BindingError(f"cannot read policy {path}: {error.strerror}") from error
        try:
            data_text = data_bytes.decode("utf-8")
            data = json.loads(data_text)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BindingError(f"policy is not valid UTF-8 JSON: {error}") from error
        require(isinstance(data, dict), "policy: top level must be an object")
        allowed = {"schema_version", "namespace", "abi", "declarations"}
        cls._exact_keys(data, allowed, "policy")
        require(data.get("schema_version") == SCHEMA_VERSION,
                f"policy: schema_version must be {SCHEMA_VERSION}")
        namespace = data.get("namespace")
        require(isinstance(namespace, str) and bool(C_IDENTIFIER.fullmatch(namespace)),
                "policy: namespace must be a C identifier")
        abi = data.get("abi")
        require(isinstance(abi, dict), "policy: abi must be an object")
        cls._exact_keys(abi, {"target", "data_model", "plain_char", "enum_policy"}, "policy abi")
        expected = {
            "target": SUPPORTED_TARGET,
            "data_model": "lp64",
            "plain_char": "signed",
            "enum_policy": "clang-default",
        }
        for key, value in expected.items():
            require(abi.get(key) == value,
                    f"policy abi: {key} must be {value!r}, got {abi.get(key)!r}")
        raw_entries = data.get("declarations")
        require(isinstance(raw_entries, list) and raw_entries,
                "policy: declarations must be a nonempty array")
        entries: list[PolicyEntry] = []
        seen: set[tuple[str, str]] = set()
        for index, raw in enumerate(raw_entries, 1):
            require(isinstance(raw, dict), f"policy declaration {index}: must be an object")
            kind = raw.get("kind")
            name = raw.get("name")
            require(kind in {"alias", "callback", "enum", "function", "incoming_varargs", "record", "variable"},
                    f"policy declaration {index}: unknown kind {kind!r}")
            require(isinstance(name, str) and name,
                    f"policy declaration {index}: name must be a nonempty string")
            duplicate = (kind, name)
            require(duplicate not in seen,
                    f"policy declaration {index}: duplicate selection {kind} {name!r}")
            seen.add(duplicate)
            context = f"policy declaration {index} ({kind} {name!r})"
            landin_name = raw.get("landin_name", sanitize_landin(name.lstrip("@").split()[-1]))
            landin_name = require_landin_name(landin_name, context)
            cls._validate_entry(raw, kind, context)
            entries.append(PolicyEntry(kind, name, landin_name, raw, index))
        return cls(namespace, dict(abi), entries, sha256_bytes(data_bytes))

    @staticmethod
    def _exact_keys(value: Mapping[str, Any], allowed: set[str], context: str) -> None:
        unknown = sorted(set(value) - allowed)
        require(not unknown, f"{context}: unknown key {(unknown[0] if unknown else '<none>')!r}")
        missing = sorted(allowed - set(value))
        require(not missing, f"{context}: missing required key {(missing[0] if missing else '<none>')!r}")

    @classmethod
    def _validate_entry(cls, raw: Mapping[str, Any], kind: str, context: str) -> None:
        common = {"kind", "name", "landin_name"}
        required: set[str]
        optional: set[str]
        if kind == "record":
            required, optional = {"representation", "fields"}, set()
            require(raw.get("representation") in {"auto", "native", "opaque"},
                    f"{context}: representation must be auto, native, or opaque")
            require(isinstance(raw.get("fields"), dict), f"{context}: fields must be an object")
        elif kind == "callback":
            required, optional = {"nullable", "parameters"}, {"result"}
            require(isinstance(raw.get("nullable"), bool), f"{context}: nullable must be Boolean")
            require(isinstance(raw.get("parameters"), dict), f"{context}: parameters must be an object")
        elif kind == "function":
            required, optional = {"direction", "parameters"}, {"result"}
            require(raw.get("direction") in {"import", "export"},
                    f"{context}: direction must be import or export")
            require(isinstance(raw.get("parameters"), dict), f"{context}: parameters must be an object")
        elif kind == "variable":
            required, optional = {"storage", "writable"}, {"value"}
            require(raw.get("storage") in {"import", "define"},
                    f"{context}: storage must be import or define")
            require(isinstance(raw.get("writable"), bool), f"{context}: writable must be Boolean")
        elif kind == "incoming_varargs":
            required = {"handler", "count_parameter", "schema", "parameters"}
            optional = {"result"}
            require(isinstance(raw.get("handler"), str) and C_IDENTIFIER.fullmatch(raw["handler"]),
                    f"{context}: handler must be a C identifier")
            require(raw.get("handler") != raw.get("name"),
                    f"{context}: handler must differ from the variadic entry name")
            require(isinstance(raw.get("count_parameter"), str),
                    f"{context}: count_parameter must be a parameter name")
            require(isinstance(raw.get("parameters"), dict), f"{context}: parameters must be an object")
            schema = raw.get("schema")
            require(isinstance(schema, list) and schema,
                    f"{context}: schema must be a nonempty array")
            seen_names: set[str] = set()
            for at, item in enumerate(schema, 1):
                item_context = f"{context} schema item {at}"
                require(isinstance(item, dict), f"{item_context}: must be an object")
                allowed = {"name", "promoted"}
                if item.get("promoted") == "pointer":
                    allowed.add("policy")
                cls._exact_keys(item, allowed, item_context)
                tail_name = item.get("name")
                require(isinstance(tail_name, str) and C_IDENTIFIER.fullmatch(tail_name),
                        f"{item_context}: name must be a C identifier")
                require(tail_name not in seen_names, f"{item_context}: duplicate name {tail_name!r}")
                seen_names.add(tail_name)
                require(item.get("promoted") in PROMOTED_TYPES,
                        f"{item_context}: unsupported promoted type {item.get('promoted')!r}")
        else:
            required, optional = set(), set()
        allowed = common | required | optional
        unknown = sorted(set(raw) - allowed)
        require(not unknown, f"{context}: unknown key {(unknown[0] if unknown else '<none>')!r}")
        missing = sorted(required - set(raw))
        require(not missing, f"{context}: missing required key {(missing[0] if missing else '<none>')!r}")


def validate_annotation(value: Any, context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context}: pointer policy must be an object")
    expected = {"ownership", "nullability", "from", "retention"}
    unknown = sorted(set(value) - expected)
    missing = sorted(expected - set(value))
    require(not unknown, f"{context}: unknown pointer-policy key {(unknown[0] if unknown else '<none>')!r}")
    require(not missing, f"{context}: missing pointer-policy key {(missing[0] if missing else '<none>')!r}")
    require(value["ownership"] in {"borrowed", "caller_owned", "c_owned", "static", "transferred"},
            f"{context}: unsupported ownership {value['ownership']!r}")
    require(value["nullability"] in {"nonnullable", "nullable"},
            f"{context}: nullability must be nonnullable or nullable")
    require(value["retention"] in {"call", "returned", "static", "stored"},
            f"{context}: unsupported retention {value['retention']!r}")
    sources = value["from"]
    require(isinstance(sources, list) and all(isinstance(item, str) and C_IDENTIFIER.fullmatch(item)
                                             for item in sources),
            f"{context}: from must be an array of parameter names")
    require(len(sources) == len(set(sources)), f"{context}: from names must be unique")
    return {
        "ownership": value["ownership"], "nullability": value["nullability"],
        "from": list(sources), "retention": value["retention"],
    }


def parse_header_argument(value: str) -> tuple[str, pathlib.Path]:
    if "=" in value:
        logical, raw_path = value.split("=", 1)
    else:
        raw_path = value
        logical = pathlib.Path(value).name
    logical_path = pathlib.PurePosixPath(logical)
    require(logical and not logical_path.is_absolute() and ".." not in logical_path.parts and
            logical_path.as_posix() == logical and logical not in {".", ""},
            f"--header logical name must be a canonical relative include path, got {logical!r}")
    require("\\" not in logical and '"' not in logical and
            all(32 <= ord(character) != 127 for character in logical),
            f"--header logical name is not safe for #include: {logical!r}")
    path = pathlib.Path(raw_path).expanduser().resolve()
    require(path.is_file(), f"--header {raw_path!r} is not a regular file")
    return logical, path


@dataclasses.dataclass
class ToolInputs:
    clang: pathlib.Path
    target: str
    sysroot: pathlib.Path
    headers: list[HeaderInput]
    include_dirs: list[pathlib.Path]
    system_include_dirs: list[pathlib.Path]
    defines: list[str]
    policy_path: pathlib.Path
    out_dir: pathlib.Path


def clang_environment() -> dict[str, str]:
    # A whitelist also removes future include/driver override variables, not
    # just CPATH/C_INCLUDE_PATH. The executable itself was explicitly selected.
    environment = {name: os.environ[name] for name in
                   ("PATH", "HOME", "TMPDIR", "TMP", "TEMP", "SystemRoot")
                   if name in os.environ}
    environment.update(LC_ALL="C", TZ="UTC")
    return environment


class ClangDriver:
    def __init__(self, inputs: ToolInputs, include_map: pathlib.Path) -> None:
        self.inputs = inputs
        self.include_map = include_map
        self.prefix_maps = [(inputs.sysroot, "sysroot"),
                            (include_map.parent, ".")]
        self.prefix_maps.extend((path, f"include/{index}")
                                for index, path in enumerate(inputs.include_dirs, 1))
        self.prefix_maps.extend((path, f"system/{index}")
                                for index, path in enumerate(inputs.system_include_dirs, 1))

    def arguments(self) -> list[str]:
        result = [
            str(self.inputs.clang), f"--target={self.inputs.target}", "--no-default-config",
            f"--sysroot={self.inputs.sysroot}", "-std=c11", "-fno-short-enums", "-nostdinc",
            "-Wsystem-headers", "-Werror=date-time", "-iquote", str(self.include_map),
        ]
        # Clang applies the last matching map; prefer the most specific root.
        result.extend(f"-ffile-prefix-map={path}={logical}" for path, logical in
                      sorted(self.prefix_maps, key=lambda item: len(str(item[0]))))
        for directory in self.inputs.include_dirs:
            result.extend(("-I", str(directory)))
        for directory in self.inputs.system_include_dirs:
            result.extend(("-isystem", str(directory)))
        for define in self.inputs.defines:
            result.append("-D" + define)
        return result

    def run(self, extra: Sequence[str], *, input_bytes: bytes | None = None,
            context: str) -> subprocess.CompletedProcess[bytes]:
        command = self.arguments() + list(extra)
        try:
            process = subprocess.run(command, input=input_bytes, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, check=False,
                                     env=clang_environment())
        except OSError as error:
            raise BindingError(f"cannot execute Clang {self.inputs.clang}: {error.strerror}") from error
        if process.returncode != 0:
            detail = self.sanitize_diagnostic(process.stderr.decode("utf-8", "replace")).strip()
            raise BindingError(f"Clang failed while {context}:\n{detail}")
        return process

    def sanitize_diagnostic(self, text: str) -> str:
        replacements: list[tuple[str, str]] = [
            (str(self.include_map), "<headers>"),
            (str(self.include_map.parent), "<work>"),
        ]
        replacements.extend((str(header.path), header.logical) for header in self.inputs.headers)
        replacements.append((str(self.inputs.sysroot), "<sysroot>"))
        replacements.extend((str(value), f"<include-{index}>")
                            for index, value in enumerate(self.inputs.include_dirs, 1))
        replacements.extend((str(value), f"<system-include-{index}>")
                            for index, value in enumerate(self.inputs.system_include_dirs, 1))
        for old, new in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
            text = text.replace(old, new)
        return text

    def verify_target(self) -> dict[str, str]:
        triple_process = self.run(("-print-target-triple",), context="querying the target triple")
        triple = triple_process.stdout.decode("ascii", "replace").strip()
        require(triple == SUPPORTED_TARGET,
                f"Clang selected target {triple!r}; required {SUPPORTED_TARGET!r}")
        macros_process = self.run(("-dM", "-E", "-x", "c", "-"), input_bytes=b"",
                                  context="probing the target ABI")
        macros: dict[str, str] = {}
        for line in macros_process.stdout.decode("utf-8", "replace").splitlines():
            match = re.match(r"#define ([A-Za-z_][A-Za-z0-9_]*)(?: (.*))?\Z", line)
            if match:
                macros[match.group(1)] = match.group(2) or "1"
        required = {
            "__x86_64__": "1", "__linux__": "1", "__ELF__": "1", "__LP64__": "1",
            "__CHAR_BIT__": "8", "__SIZEOF_SHORT__": "2", "__SIZEOF_INT__": "4",
            "__SIZEOF_LONG__": "8", "__SIZEOF_LONG_LONG__": "8",
            "__SIZEOF_POINTER__": "8", "__SIZEOF_SIZE_T__": "8",
            "__SIZEOF_PTRDIFF_T__": "8", "__SIZEOF_FLOAT__": "4",
            "__SIZEOF_DOUBLE__": "8", "__FLT_RADIX__": "2",
            "__FLT_MANT_DIG__": "24", "__DBL_MANT_DIG__": "53",
        }
        for name, expected in required.items():
            require(macros.get(name) == expected,
                    f"unsupported Clang target ABI: {name} is {macros.get(name)!r}, expected {expected!r}")
        require("__CHAR_UNSIGNED__" not in macros,
                "unsupported Clang target ABI: plain char is unsigned")
        byte_order = macros.get("__BYTE_ORDER__")
        little_order = macros.get("__ORDER_LITTLE_ENDIAN__")
        require(byte_order == little_order or byte_order == "__ORDER_LITTLE_ENDIAN__",
                "unsupported Clang target ABI: target is not little-endian")
        return macros

    def parse_ast(self, translation: pathlib.Path) -> dict[str, Any]:
        process = self.run(("-Xclang", "-ast-dump=json", "-fsyntax-only", str(translation)),
                           context="parsing selected headers")
        try:
            value = json.loads(process.stdout)
        except json.JSONDecodeError as error:
            raise BindingError(f"Clang emitted invalid JSON AST: {error}") from error
        require(isinstance(value, dict) and value.get("kind") == "TranslationUnitDecl",
                "Clang JSON AST has no translation unit root")
        return value

    def preprocess(self, translation: pathlib.Path) -> pathlib.Path:
        process = self.run(("-E", str(translation)), context="preprocessing selected headers")
        lines: list[bytes] = []
        marker = re.compile(rb'^#\s+\d+\s+("(?:[^"\\\\]|\\\\.)*")')
        for line in process.stdout.splitlines(keepends=True):
            match = marker.match(line)
            if not match:
                lines.append(line)
                continue
            location = python_ast.literal_eval(match.group(1).decode("utf-8"))
            path = pathlib.Path(location)
            if path.is_absolute():
                require(any(path.is_relative_to(root) for root, _ in self.prefix_maps),
                        "unsupported path-sensitive preprocessing outside explicit roots; "
                        "add the transitive header's root with --include-dir or --system-include-dir")
        # This is Clang's preprocessed C, not a parsed/reconstructed header.
        # Physical byte offsets in its AST let the enum probe name anonymous
        # declarations without guessing integer types from enumerator expressions.
        preprocessed = translation.with_suffix(".i")
        preprocessed.write_bytes(b"".join(lines))
        return preprocessed

    def query_enum_types(self, model: ASTModel, translation: pathlib.Path,
                         enums: Sequence[EnumInfo]) -> None:
        if not enums:
            return
        source = translation.read_bytes()
        prefix = "landin_enum_probe_"
        while any(name.startswith(prefix) for name in model.identifiers):
            prefix += "x_"
        edits: list[tuple[int, bytes]] = []
        queries: list[str] = []
        candidates = [name for name in BUILTIN_LAYOUT
                      if name not in {"float", "double", "_Bool"}]
        for index, enum in enumerate(enums):
            c_name = enum.c_name
            if not c_name:
                offset = enum.node.get("loc", {}).get("offset")
                require(isinstance(offset, int) and source[offset:offset + 4] == b"enum",
                        "Clang did not provide a usable anonymous enum location")
                tag = f"{prefix}tag_{index}"
                edits.append((offset + 4, (" " + tag).encode("ascii")))
                c_name = "enum " + tag
            expression = " + ".join(
                f"{code} * __builtin_types_compatible_p({c_name}, {candidate})"
                for code, candidate in enumerate(candidates, 1))
            queries.append(f"enum {{ {prefix}type_{index} = {expression} }};")
        for offset, insertion in sorted(edits, reverse=True):
            source = source[:offset] + insertion + source[offset:]
        probe = translation.with_name("enum-probe.i")
        probe.write_bytes(source + b"\n" + "\n".join(queries).encode("utf-8") + b"\n")
        queried = ASTModel(self.parse_ast(probe))
        values = {name: value for enum in queried.enums
                  for name, value in Generator.enum_values(enum)}
        for index, enum in enumerate(enums):
            code = values.get(f"{prefix}type_{index}", 0)
            require(1 <= code <= len(candidates),
                    f"enum {enum.display_name!r}: unsupported Clang compatible integer type")
            enum.compatible_type = candidates[code - 1]

    def validate_c(self, adapters: pathlib.Path, staging: pathlib.Path) -> None:
        self.run(("-iquote", str(staging), "-Wall", "-Wextra", "-Werror", "-fsyntax-only",
                  str(adapters)), context="validating generated adapters")

@dataclasses.dataclass
class CFunction:
    result: str
    name: str
    parameters: list[str]
    body: list[str]

    def prototype(self) -> str:
        arguments = ", ".join(self.parameters) if self.parameters else "void"
        return f"{self.result} {self.name}({arguments});"

    def definition(self) -> str:
        arguments = ", ".join(self.parameters) if self.parameters else "void"
        lines = [f"{self.result} {self.name}({arguments})", "{"]
        lines.extend(f"    {line}" if line else "" for line in self.body)
        lines.append("}")
        return "\n".join(lines)


@dataclasses.dataclass
class OptionalType:
    name: str
    absent: str
    member_type: str


class Generator:
    def __init__(self, ast: ASTModel, policy: Policy, headers: Sequence[HeaderInput]) -> None:
        self.ast = ast
        self.types = TypeParser(ast)
        self.policy = policy
        self.headers = list(headers)
        self.records_by_id = {record.identity: record for record in ast.records}
        self.enums_by_id = {enum.identity: enum for enum in ast.enums}
        self.record_entries: dict[str, PolicyEntry] = {}
        self.enum_entries: dict[str, PolicyEntry] = {}
        self.callback_entries: dict[str, PolicyEntry] = {}
        self.alias_entries: dict[str, PolicyEntry] = {}
        self.function_entries: list[tuple[PolicyEntry, dict[str, Any]]] = []
        self.variable_entries: list[tuple[PolicyEntry, dict[str, Any]]] = []
        self.incoming_entries: list[tuple[PolicyEntry, dict[str, Any]]] = []
        self.annotations: dict[tuple[str, str], dict[str, Any]] = {}
        self.needed_records: set[str] = set()
        self.needed_enums: set[str] = set()
        self.needed_aliases: set[str] = set()
        self.needed_callbacks: set[str] = set()
        self.optional_types: dict[str, OptionalType] = {}
        self.c_functions: list[CFunction] = []
        self.c_definitions: list[str] = []
        self.c_assertions: list[str] = []
        self.export_declarations: list[str] = []
        self.ldn_type_blocks: list[str] = []
        self.ldn_declarations: list[str] = []
        self.metadata_declarations: list[dict[str, Any]] = []
        self.needs_stdlib = False
        self.needs_stdarg = False
        self._landin_names: dict[str, str] = {}
        # Incoming handlers are policy-supplied symbols whose declarations are
        # generated here. Reserve them from generated adapter symbols and locals.
        self._c_symbols: set[str] = {
            entry.raw["handler"] for entry in policy.entries
            if entry.kind == "incoming_varargs"
        }
        self.callback_cell_structs: dict[str, str] = {}
        self._resolve_policy()

    def ensure_typedef_unattributed(self, name: str, context: str) -> None:
        node = self.ast.typedefs[name]
        attributes = [item.get("kind", "") for item in node.get("inner", [])
                      if item.get("kind", "").endswith("Attr")]
        require(not attributes,
                f"{context}: unsupported typedef attribute {(attributes[0] if attributes else '<none>')}")

    def _resolve_policy(self) -> None:
        callable_names: set[str] = set()
        for entry in self.policy.entries:
            self._claim_landin(entry.landin_name, entry.context)
            if entry.kind == "record":
                record = self.ast.record(entry.name)
                require(record is not None,
                        f"{entry.context}: selected record was not found in Clang AST (stale policy)")
                if entry.name in self.ast.typedefs:
                    self.ensure_typedef_unattributed(entry.name, entry.context)
                require(record.identity not in self.record_entries,
                        f"{entry.context}: record aliases select the same C declaration twice")
                self.record_entries[record.identity] = entry
                self.needed_records.add(record.identity)
            elif entry.kind == "enum":
                enum = self.ast.enum(entry.name)
                require(enum is not None,
                        f"{entry.context}: selected enum was not found in Clang AST (stale policy)")
                if entry.name in self.ast.typedefs:
                    self.ensure_typedef_unattributed(entry.name, entry.context)
                require(enum.identity not in self.enum_entries,
                        f"{entry.context}: enum aliases select the same C declaration twice")
                self.enum_entries[enum.identity] = entry
                self.needed_enums.add(enum.identity)
            elif entry.kind in {"callback", "alias"}:
                node = self.ast.typedefs.get(entry.name)
                require(node is not None,
                        f"{entry.context}: selected typedef was not found in Clang AST (stale policy)")
                self.ensure_typedef_unattributed(entry.name, entry.context)
                parsed = self.types.alias(entry.name)
                resolved = self.resolve_alias(parsed)
                if entry.kind == "callback":
                    self.ensure_supported(parsed, entry.context)
                    require(resolved.kind == "callback",
                            f"{entry.context}: selected typedef is not a function pointer")
                    self.callback_entries[entry.name] = entry
                    self.needed_callbacks.add(entry.name)
                else:
                    require(resolved.kind not in {"callback", "record", "enum"},
                            f"{entry.context}: aggregate, enum, or function-pointer typedef must use its matching policy kind")
                    self.alias_entries[entry.name] = entry
                    self.needed_aliases.add(entry.name)
            elif entry.kind in {"function", "incoming_varargs"}:
                require(entry.name not in callable_names,
                        f"{entry.context}: C function is selected more than once across callable policy kinds")
                callable_names.add(entry.name)
                node = self.ast.function(entry.name)
                require(node is not None,
                        f"{entry.context}: selected function was not found in Clang AST (stale policy)")
                if entry.kind == "function":
                    self.function_entries.append((entry, node))
                else:
                    self.incoming_entries.append((entry, node))
            elif entry.kind == "variable":
                node = self.ast.variable(entry.name)
                require(node is not None,
                        f"{entry.context}: selected variable was not found in Clang AST (stale policy)")
                self.variable_entries.append((entry, node))

    def _claim_landin(self, name: str, context: str) -> None:
        previous = self._landin_names.get(name)
        require(previous is None, f"{context}: Landin name {name!r} collides with {previous}")
        self._landin_names[name] = context

    def _claim_generated_landin(self, name: str, context: str) -> str:
        name = sanitize_landin(name)
        self._claim_landin(name, context)
        return name

    def c_symbol(self, *parts: str) -> str:
        clean = [re.sub(r"[^A-Za-z0-9_]", "_", part) for part in parts]
        symbol = "landin_" + self.policy.namespace + "_" + "_".join(clean)
        require(C_IDENTIFIER.fullmatch(symbol) is not None, f"cannot form adapter symbol from {parts!r}")
        require(symbol not in self._c_symbols, f"generated C symbol collision: {symbol}")
        self._c_symbols.add(symbol)
        return symbol

    def c_locals(self, *names: str) -> tuple[str, ...]:
        # C typedefs and objects share the ordinary identifier namespace with
        # parameters/locals. Reserve every header declaration, not just the
        # selected record: casts can also name nested types and called functions.
        used = self.ast.identifiers | self._c_symbols
        result = []
        for name in names:
            while name in used:
                name += "_"
            used.add(name)
            result.append(name)
        return tuple(result)

    @staticmethod
    def resolve_alias(ctype: CType) -> CType:
        seen: set[str] = set()
        qualified_const = ctype.const
        while ctype.kind == "alias":
            require(ctype.name not in seen, f"recursive typedef {ctype.name!r}")
            seen.add(ctype.name)
            require(ctype.child is not None, f"typedef {ctype.name!r} has no target")
            ctype = ctype.child
            qualified_const = qualified_const or ctype.const
        return dataclasses.replace(ctype, const=True) if qualified_const and not ctype.const else ctype

    def record_for(self, ctype: CType) -> RecordInfo:
        resolved = self.resolve_alias(ctype)
        require(resolved.kind == "record" and resolved.name in self.records_by_id,
                f"internal: missing record for {ctype.spelling}")
        return self.records_by_id[resolved.name]

    def enum_for(self, ctype: CType) -> EnumInfo:
        resolved = self.resolve_alias(ctype)
        require(resolved.kind == "enum" and resolved.name in self.enums_by_id,
                f"internal: missing enum for {ctype.spelling}")
        return self.enums_by_id[resolved.name]

    def contains_reference(self, ctype: CType,
                           visiting: frozenset[str] = frozenset()) -> bool:
        resolved = self.resolve_alias(ctype)
        if resolved.kind in {"pointer", "callback"}:
            return True
        if resolved.kind == "array" and resolved.child:
            return self.contains_reference(resolved.child, visiting)
        if resolved.kind == "record" and resolved.name not in visiting:
            record = self.records_by_id[resolved.name]
            return any(self.contains_reference(self.types.from_info(field["type"]),
                                               visiting | {resolved.name})
                       for field in record.fields)
        return False

    def ensure_supported(self, ctype: CType, context: str, *, allow_void: bool = False) -> None:
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "unsupported":
            raise BindingError(f"{context}: unsupported {resolved.name}: {resolved.spelling}")
        if resolved.kind == "builtin":
            if resolved.name == "void":
                require(allow_void, f"{context}: void is not a value type")
            return
        if resolved.kind == "pointer":
            require(resolved.child is not None, f"{context}: pointer has no pointee")
            pointee = self.resolve_alias(resolved.child)
            if pointee.kind == "function":
                raise BindingError(f"{context}: unsupported unprototyped or unnamed function pointer")
            if pointee.kind == "callback" and resolved.child.kind != "alias":
                raise BindingError(f"{context}: pointer to an unnamed function-pointer cell is unsupported")
            if pointee.kind == "unsupported":
                raise BindingError(f"{context}: unsupported pointer pointee {pointee.name}: {pointee.spelling}")
            return
        if resolved.kind == "callback":
            require(not resolved.old_style, f"{context}: old-style function type is unsupported")
            require(not resolved.variadic or resolved.parameters,
                    f"{context}: variadic callback needs at least one fixed parameter")
            inner_references = (self.contains_reference(resolved.result) or  # type: ignore[arg-type]
                                any(self.contains_reference(p) for p in resolved.parameters))
            require(not inner_references or ctype.kind == "alias",
                    f"{context}: anonymous callback with reference positions requires an explicitly annotated named callback typedef")
            self.ensure_supported(resolved.result, context + " result", allow_void=True)  # type: ignore[arg-type]
            for index, parameter in enumerate(resolved.parameters, 1):
                self.ensure_supported(parameter, f"{context} parameter {index}")
            return
        if resolved.kind == "array":
            require(resolved.count > 0, f"{context}: flexible or zero-size array is unsupported")
            self.ensure_supported(resolved.child, context + " element")  # type: ignore[arg[arg-type]
            return
        if resolved.kind == "record":
            record = self.record_for(resolved)
            require(record.complete, f"{context}: incomplete record is not a by-value type")
            return
        if resolved.kind == "enum":
            require(bool(self.enum_for(resolved).constants), f"{context}: empty enum is unsupported")
            return
        raise BindingError(f"{context}: unsupported type {resolved.spelling}")

    def ctype_for_parameter(self, node: Mapping[str, Any]) -> CType:
        return self.types.from_info(node["type"])

    def function_result(self, node: Mapping[str, Any], context: str) -> CType:
        spelling = node.get("type", {}).get("qualType")
        require(isinstance(spelling, str), f"{context}: Clang function type is missing")
        parsed = split_function_spelling(spelling)
        require(parsed is not None,
                f"{context}: unsupported nested function return declarator {spelling!r}; use a named callback typedef")
        return self.types.parse(parsed[0])

    @staticmethod
    def function_parameters(node: Mapping[str, Any]) -> list[dict[str, Any]]:
        return [item for item in node.get("inner", []) if item.get("kind") == "ParmVarDecl"]

    def validate_function_shape(self, entry: PolicyEntry, node: Mapping[str, Any]) -> tuple[list[dict[str, Any]], CType]:
        context = entry.context
        spelling = node.get("type", {}).get("qualType", "")
        params = self.function_parameters(node)
        parameter_names = [sanitize_landin(parameter.get("name") or f"argument_{index}")
                           for index, parameter in enumerate(params, 1)]
        require(len(parameter_names) == len(set(parameter_names)),
                f"{context}: parameter names collide after Landin normalization")
        if not params and re.search(r"\(\s*\)\s*$", spelling):
            raise BindingError(f"{context}: old-style function declaration is unsupported")
        require("__attribute__" not in spelling,
                f"{context}: unsupported calling convention or function type attribute: {spelling}")

        def validate_attributes(value: Mapping[str, Any]) -> None:
            kind = value.get("kind", "")
            if kind == "CompoundStmt":
                return  # Local implementation attributes do not change its ABI.
            require(not kind.endswith("Attr"),
                    f"{context}: unsupported calling convention or parameter/function attribute {kind}")
            for child in value.get("inner", []):
                validate_attributes(child)

        validate_attributes(node)
        result = self.function_result(node, context)
        self.ensure_supported(result, context + " result", allow_void=True)
        for index, parameter in enumerate(params, 1):
            self.ensure_supported(self.ctype_for_parameter(parameter),
                                  f"{context} parameter {parameter.get('name') or index}")
        return params, result

    def validate_site_annotations(self, entry: PolicyEntry, params: Sequence[dict[str, Any]], result: CType,
                                  *, extra_result_required: bool = False) -> tuple[dict[str, dict[str, Any]], dict[str, Any] | None]:
        raw_parameters = entry.raw.get("parameters", {})
        actual_names: list[str] = []
        annotations: dict[str, dict[str, Any]] = {}
        for index, node in enumerate(params, 1):
            c_name = node.get("name") or f"argument_{index}"
            actual_names.append(c_name)
            ctype = self.ctype_for_parameter(node)
            if self.contains_reference(ctype):
                require(c_name in raw_parameters,
                        f"{entry.context} parameter {c_name!r}: missing required pointer policy")
                annotations[c_name] = validate_annotation(
                    raw_parameters[c_name], f"{entry.context} parameter {c_name!r}")
                require(annotations[c_name]["from"] == [],
                        f"{entry.context} parameter {c_name!r}: from must be empty")
            else:
                require(c_name not in raw_parameters,
                        f"{entry.context} parameter {c_name!r}: stale policy for non-reference value")
        stale = sorted(set(raw_parameters) - set(actual_names))
        require(not stale, f"{entry.context}: parameter {(stale[0] if stale else '<none>')!r} is absent from header (stale policy)")
        result_annotation: dict[str, Any] | None = None
        if self.contains_reference(result) or extra_result_required:
            require("result" in entry.raw, f"{entry.context} result: missing required pointer policy")
            result_annotation = validate_annotation(entry.raw["result"], f"{entry.context} result")
            unknown_sources = sorted(set(result_annotation["from"]) - set(actual_names))
            require(not unknown_sources,
                    f"{entry.context} result: from names absent parameter {(unknown_sources[0] if unknown_sources else '<none>')!r}")
            require(all(name in annotations for name in result_annotation["from"]),
                    f"{entry.context} result: from must name reference-bearing parameters")
        else:
            require("result" not in entry.raw,
                    f"{entry.context} result: stale policy for non-reference value")
        return annotations, result_annotation

    def enum_underlying(self, enum: EnumInfo) -> CType:
        require(bool(enum.constants), f"enum {enum.display_name!r}: empty enum is unsupported")
        require(enum.compatible_type is not None,
                f"enum {enum.display_name!r}: compatible integer type was not queried from Clang")
        return self.types.parse(enum.compatible_type)

    @staticmethod
    def enum_values(enum: EnumInfo) -> list[tuple[str, int]]:
        values: list[tuple[str, int]] = []
        previous = -1
        for constant in enum.constants:
            found: str | None = None

            def walk(node: Any) -> None:
                nonlocal found
                if found is not None or not isinstance(node, dict):
                    return
                if node.get("kind") == "ConstantExpr" and "value" in node:
                    found = node["value"]
                    return
                for child in node.get("inner", []):
                    walk(child)

            walk(constant)
            value = previous + 1 if found is None else int(found, 0)
            values.append((constant["name"], value))
            previous = value
        return values

    def record_has_forbidden_attribute(self, record: RecordInfo) -> str | None:
        for item in record.node.get("inner", []):
            kind = item.get("kind", "")
            if kind.endswith("Attr"):
                return kind
        return None

    def native_field_possible(self, ctype: CType) -> bool:
        resolved = self.resolve_alias(ctype)
        if resolved.kind in {"builtin", "pointer", "callback", "enum"}:
            return True
        if resolved.kind == "array":
            return bool(resolved.child and resolved.count > 0 and
                        self.native_field_possible(resolved.child))
        if resolved.kind == "record":
            nested = self.records_by_id[resolved.name]
            return (nested.complete and
                    self.record_classification(nested) == "native-layout-c")
        return False

    def record_classification(self, record: RecordInfo) -> str:
        entry = self.record_entries.get(record.identity)
        for typedef_name in record.typedef_names:
            self.ensure_typedef_unattributed(
                typedef_name, entry.context if entry else f"record dependency {record.display_name!r}")
        requested = entry.raw["representation"] if entry else "auto"
        if not record.complete:
            require(requested != "native",
                    f"record {record.display_name!r}: incomplete record cannot have native representation")
            reference_policy = entry.raw.get("fields", {}) if entry else {}
            require(not reference_policy,
                    f"record {record.display_name!r}: incomplete record has no fields; policy is stale")
            return "incomplete-opaque"
        attribute = self.record_has_forbidden_attribute(record)
        if attribute:
            raise BindingError(f"record {record.display_name!r}: unsupported record attribute {attribute}")
        fields = record.fields
        require(fields, f"record {record.display_name!r}: empty or zero-size record is unsupported")
        has_bitfield = any(field.get("isBitfield") for field in fields)
        unnamed = any(not field.get("name") for field in fields)
        reference_policy = entry.raw.get("fields", {}) if entry else {}
        actual_named = {field["name"] for field in fields if field.get("name")}
        normalized_fields = [sanitize_landin(field["name"]) for field in fields
                             if field.get("name")]
        require(len(normalized_fields) == len(set(normalized_fields)),
                f"record {record.display_name!r}: field names collide after Landin normalization")
        stale = sorted(set(reference_policy) - actual_named)
        require(not stale, f"record {record.display_name!r}: field {(stale[0] if stale else '<none>')!r} is absent (stale policy)")
        nullable_field = False
        native_fields = True
        for index, field in enumerate(fields, 1):
            require(field.get("name") or field.get("isBitfield"),
                    f"record {record.display_name!r} field {index}: anonymous aggregate field is unsupported")
            field_attributes = [item.get("kind", "") for item in field.get("inner", [])
                                if item.get("kind", "").endswith("Attr")]
            require(not field_attributes,
                    f"record {record.display_name!r} field {field.get('name') or index}: unsupported field attribute {(field_attributes[0] if field_attributes else '<none>')}")
            ctype = self.types.from_info(field["type"])
            self.ensure_supported(ctype, f"record {record.display_name!r} field {field.get('name') or index}")
            native_fields = native_fields and self.native_field_possible(ctype)
            require(not self.resolve_alias(ctype).const,
                    f"record {record.display_name!r} field {field.get('name') or index}: const field unsupported")
            if self.contains_reference(ctype):
                name = field.get("name")
                require(name and name in reference_policy,
                        f"record {record.display_name!r} field {name or index}: missing required pointer policy")
                annotation = validate_annotation(reference_policy[name],
                                                 f"record {record.display_name!r} field {name!r}")
                require(annotation["from"] == [],
                        f"record {record.display_name!r} field {name!r}: from must be empty")
                self.annotations[(record.identity, name)] = annotation
                nullable_field = nullable_field or annotation["nullability"] == "nullable"
            elif field.get("name"):
                require(field["name"] not in reference_policy,
                        f"record {record.display_name!r} field {field['name']!r}: stale policy for non-reference value")
        native_possible = (not record.union and not has_bitfield and not unnamed and
                           not nullable_field and native_fields)
        if requested == "native":
            require(native_possible,
                    f"record {record.display_name!r}: selected native representation is incompatible with union, bitfield, unnamed, or nullable field")
            return "native-layout-c"
        if requested == "opaque":
            return "c-owned-opaque"
        return "native-layout-c" if native_possible else "c-owned-opaque"

    def landin_name_for_record(self, record: RecordInfo) -> str:
        entry = self.record_entries.get(record.identity)
        if entry:
            return entry.landin_name
        return sanitize_landin(record.display_name or "anonymous_record")

    def landin_name_for_enum(self, enum: EnumInfo) -> str:
        entry = self.enum_entries.get(enum.identity)
        if entry:
            return entry.landin_name
        return sanitize_landin(enum.display_name or enum.constants[0]["name"] + "_enum")

    def landin_name_for_alias(self, name: str) -> str:
        entry = self.alias_entries.get(name) or self.callback_entries.get(name)
        return entry.landin_name if entry else sanitize_landin(name)

    def register_type(self, ctype: CType, *, by_value: bool = True) -> None:
        if ctype.kind == "alias":
            if ctype.name in self.ast.records_by_typedef:
                record = self.ast.records_by_typedef[ctype.name]
                if by_value:
                    self.needed_records.add(record.identity)
            elif ctype.name in self.ast.enums_by_typedef:
                self.needed_enums.add(self.ast.enums_by_typedef[ctype.name].identity)
            elif self.resolve_alias(ctype).kind == "callback":
                self.needed_callbacks.add(ctype.name)
            else:
                self.needed_aliases.add(ctype.name)
                self.register_type(ctype.child, by_value=by_value)  # type: ignore[arg-type]
            return
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "record" and by_value:
            self.needed_records.add(resolved.name)
        elif resolved.kind == "enum":
            self.needed_enums.add(resolved.name)
        elif resolved.kind == "array" and resolved.child:
            self.register_type(resolved.child, by_value=by_value)
        elif resolved.kind == "pointer":
            # Pointers to C records stay opaque; other pointee aliases are not
            # needed to classify the carrier.
            child = self.resolve_alias(resolved.child) if resolved.child else None
            if child and child.kind not in {"record", "unsupported", "builtin"}:
                self.register_type(resolved.child, by_value=False)  # type: ignore[arg-type]
        elif resolved.kind == "callback":
            self.register_type(resolved.result, by_value=True)  # type: ignore[arg-type]
            for parameter in resolved.parameters:
                self.register_type(parameter, by_value=True)

    def collect_dependencies(self) -> None:
        for entry, node in self.function_entries + self.incoming_entries:
            params, result = self.validate_function_shape(entry, node)
            for parameter in params:
                self.register_type(self.ctype_for_parameter(parameter), by_value=True)
            self.register_type(result, by_value=True)
        for entry, node in self.variable_entries:
            ctype = self.types.from_info(node["type"])
            self.ensure_supported(ctype, entry.context)
            self.register_type(ctype, by_value=True)
        changed = True
        while changed:
            before = (len(self.needed_records), len(self.needed_enums),
                      len(self.needed_aliases), len(self.needed_callbacks))
            for identity in list(self.needed_records):
                record = self.records_by_id[identity]
                if record.complete:
                    self.record_classification(record)
                    for field in record.fields:
                        self.register_type(self.types.from_info(field["type"]), by_value=True)
            for name in list(self.needed_aliases) + list(self.needed_callbacks):
                self.register_type(self.types.alias(name).child, by_value=True)  # type: ignore[arg-type]
            after = (len(self.needed_records), len(self.needed_enums),
                     len(self.needed_aliases), len(self.needed_callbacks))
            changed = before != after

    def layout_of(self, ctype: CType, stack: tuple[str, ...] = ()) -> tuple[int, int]:
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "builtin":
            require(resolved.name in BUILTIN_LAYOUT,
                    f"unsupported layout for {resolved.spelling}")
            return BUILTIN_LAYOUT[resolved.name]
        if resolved.kind in {"pointer", "callback"}:
            return (8, 8)
        if resolved.kind == "enum":
            return self.layout_of(self.enum_underlying(self.enum_for(resolved)), stack)
        if resolved.kind == "array":
            require(resolved.count > 0, f"unsupported array extent in {resolved.spelling}")
            size, alignment = self.layout_of(resolved.child, stack)  # type: ignore[arg-type]
            return size * resolved.count, alignment
        if resolved.kind == "record":
            require(resolved.name not in stack, "recursive by-value record layout")
            record = self.records_by_id[resolved.name]
            require(self.record_classification(record) == "native-layout-c",
                    f"record {record.display_name!r} has no native Landin layout")
            size = 0
            alignment = 1
            for field in record.fields:
                field_size, field_alignment = self.layout_of(
                    self.types.from_info(field["type"]), stack + (resolved.name,))
                size = align_up(size, field_alignment) + field_size
                alignment = max(alignment, field_alignment)
            return align_up(size, alignment), alignment
        raise BindingError(f"unsupported layout type {resolved.spelling}")

    def record_layout(self, record: RecordInfo) -> tuple[int, int, list[tuple[str, int]]]:
        size = 0
        alignment = 1
        offsets: list[tuple[str, int]] = []
        for field in record.fields:
            field_size, field_alignment = self.layout_of(self.types.from_info(field["type"]),
                                                         (record.identity,))
            size = align_up(size, field_alignment)
            offsets.append((field["name"], size))
            size += field_size
            alignment = max(alignment, field_alignment)
        return align_up(size, alignment), alignment, offsets

    def native_by_value(self, ctype: CType) -> bool:
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "record":
            return self.record_classification(self.records_by_id[resolved.name]) == "native-layout-c"
        if resolved.kind == "array":
            return False
        return resolved.kind in {"builtin", "pointer", "callback", "enum"}

    def opaque_by_value(self, ctype: CType) -> bool:
        resolved = self.resolve_alias(ctype)
        return resolved.kind == "record" and not self.native_by_value(resolved)

    def c_type(self, ctype: CType) -> str:
        if ctype.kind == "alias":
            return ("const " if ctype.const else "") + ctype.name
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "builtin":
            return ("const " if resolved.const else "") + resolved.name
        if resolved.kind == "record":
            return ("const " if resolved.const else "") + self.records_by_id[resolved.name].c_name
        if resolved.kind == "enum":
            return ("const " if resolved.const else "") + self.enums_by_id[resolved.name].c_name
        if resolved.kind in {"pointer", "array", "callback", "function"}:
            return self.c_declarator(resolved, "").strip()
        raise BindingError(f"cannot render C type {resolved.spelling}")

    def c_declarator(self, ctype: CType, name: str) -> str:
        if ctype.kind == "alias":
            qualifier = "const " if ctype.const else ""
            return f"{qualifier}{ctype.name} {name}"
        resolved = self.resolve_alias(ctype)
        if resolved.kind in {"callback", "function"}:
            params = ", ".join(self.c_type(value) for value in resolved.parameters) or "void"
            if resolved.variadic:
                params += ", ..." if params != "void" else "..."
            if resolved.kind == "callback":
                qualifier = " const " if resolved.const else ""
                name = f"(*{qualifier}{name})"
            return self.c_declarator(resolved.result, f"{name}({params})")  # type: ignore[arg-type]
        if resolved.kind == "array":
            return self.c_declarator(resolved.child, f"{name}[{resolved.count}]")  # type: ignore[arg-type]
        if resolved.kind == "pointer":
            qualifier = " const " if resolved.const else ""
            name = f"*{qualifier}{name}"
            if self.resolve_alias(resolved.child).kind in {"array", "function"}:  # type: ignore[arg-type]
                name = f"({name})"
            return self.c_declarator(resolved.child, name)  # type: ignore[arg-type]
        return f"{self.c_type(ctype)} {name}"

    def c_prototype_parameter(self, ctype: CType, name: str) -> str:
        # A parameter name can hide a header typedef before a later parameter
        # needs it. Names are optional in prototypes, so retain policy/header
        # spellings except where omission keeps the declaration unambiguous.
        declarator_name = "" if name in self.ast.typedefs else name
        return self.c_declarator(ctype, declarator_name).strip()

    def optional_for(self, site: str, member_type: str) -> OptionalType:
        existing = self.optional_types.get(site)
        if existing:
            require(existing.member_type == member_type, f"optional type collision at {site}")
            return existing
        base = sanitize_landin(f"{self.policy.namespace}_{site}")
        absent = self._claim_generated_landin(base + "_absent", f"generated optional {site}")
        name = self._claim_generated_landin(base + "_optional", f"generated optional {site}")
        result = OptionalType(name, absent, member_type)
        self.optional_types[site] = result
        return result

    def landin_type(self, ctype: CType, *, annotation: Mapping[str, Any] | None = None,
                    site: str = "value", pointer_as_opaque: bool = False) -> str:
        if ctype.kind == "alias":
            resolved = self.resolve_alias(ctype)
            if resolved.kind == "record":
                if pointer_as_opaque:
                    return "u8"
                return self.landin_name_for_record(self.records_by_id[resolved.name])
            if resolved.kind == "enum":
                return self.landin_name_for_enum(self.enums_by_id[resolved.name])
            if resolved.kind == "callback":
                self.needed_callbacks.add(ctype.name)
                base = self.landin_name_for_alias(ctype.name)
            elif ctype.name in self.needed_aliases or ctype.name in self.alias_entries:
                base = self.landin_name_for_alias(ctype.name)
            else:
                base = self.landin_type(ctype.child, annotation=None, site=site,
                                        pointer_as_opaque=pointer_as_opaque)  # type: ignore[arg-type]
            if annotation and annotation["nullability"] == "nullable" and resolved.kind == "pointer":
                return self.optional_for(site, base).name
            return base
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "builtin":
            require(resolved.name != "void", "void has no Landin value type")
            return BUILTIN_LANDIN[resolved.name]
        if resolved.kind == "enum":
            self.needed_enums.add(resolved.name)
            return self.landin_name_for_enum(self.enums_by_id[resolved.name])
        if resolved.kind == "record":
            if pointer_as_opaque:
                return "u8"
            self.needed_records.add(resolved.name)
            return self.landin_name_for_record(self.records_by_id[resolved.name])
        if resolved.kind == "array":
            return f"[{resolved.count}]{self.landin_type(resolved.child, site=site)}"  # type: ignore[arg-type]
        if resolved.kind == "pointer":
            pointee = self.resolve_alias(resolved.child)  # type: ignore[arg-type]
            if pointee.kind in {"record", "unsupported"} or pointee.kind == "builtin" and pointee.name == "void":
                inner = "u8"
            else:
                inner = self.landin_type(resolved.child, pointer_as_opaque=True, site=site)  # type: ignore[arg-type]
            mutable = "" if pointee.const else "mut "
            base = f"ptr {mutable}{inner}"
            if annotation and annotation["nullability"] == "nullable":
                return self.optional_for(site, base).name
            return base
        if resolved.kind == "callback":
            params = [f"argument_{index}: {self.landin_type(value, site=site + '_argument')}"
                      for index, value in enumerate(resolved.parameters, 1)]
            if resolved.variadic:
                params.append("...")
            result = self.landin_return(resolved.result, None, site + "_result")  # type: ignore[arg-type]
            return f"extern(c) ({', '.join(params)}) -> {result}"
        raise BindingError(f"cannot render Landin type {resolved.spelling}")

    def landin_return(self, ctype: CType, annotation: Mapping[str, Any] | None, site: str,
                      name: str = "result") -> str:
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "builtin" and resolved.name == "void":
            return "none"
        rendered = self.landin_type(ctype, annotation=annotation, site=site)
        from_part = ""
        if annotation and annotation["from"]:
            from_part = " from " + ", ".join(sanitize_landin(value) for value in annotation["from"])
        return f"({sanitize_landin(name)}: {rendered}{from_part})"

    def retains_references(self, ctype: CType, visiting: frozenset[str] = frozenset()) -> bool:
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "array" and resolved.child:
            return self.retains_references(resolved.child, visiting)
        if resolved.kind != "record" or resolved.name in visiting:
            return False
        record = self.records_by_id[resolved.name]
        if record.complete:
            self.record_classification(record)
        nested_visiting = visiting | {resolved.name}
        for field in record.fields:
            field_type = self.types.from_info(field["type"])
            field_name = field.get("name")
            annotation = self.annotations.get((record.identity, field_name)) if field_name else None
            if annotation and annotation["retention"] in {"stored", "returned", "static"}:
                return True
            if self.retains_references(field_type, nested_visiting):
                return True
        return False

    def escaping_prefix(self, ctype: CType, annotation: Mapping[str, Any] | None,
                        *, output_store: bool = False) -> str:
        return ("escaping " if output_store or
                (annotation and annotation["retention"] in {"stored", "returned", "static"})
                or self.retains_references(ctype) else "")

    def landin_opaque_parameter(self, ctype: CType, name: str,
                                annotation: Mapping[str, Any] | None = None,
                                *, output_store: bool = False) -> str:
        # The adapter copies the C value from this address. Any retained inner
        # references must still be visible to the caller's escape analysis.
        escaping = self.escaping_prefix(ctype, annotation, output_store=output_store)
        return f"{escaping}{sanitize_landin(name)}: ptr u8"

    def landin_parameter(self, ctype: CType, c_name: str, annotation: Mapping[str, Any] | None,
                         site: str, *, output_store: bool = False) -> str:
        name = sanitize_landin(c_name)
        escaping = self.escaping_prefix(ctype, annotation, output_store=output_store)
        return f"{escaping}{name}: {self.landin_type(ctype, annotation=annotation, site=site)}"

    def require_storable_policy(self, ctype: CType, annotation: Mapping[str, Any] | None,
                                context: str) -> None:
        # Only generator-owned stores justify this check. A call-only promise
        # about an unknown foreign body remains policy, not an inferred fact.
        if self.contains_reference(ctype):
            require(annotation is not None and annotation["retention"] != "call",
                    f"{context}: retention 'call' contradicts generated retaining store; "
                    "use an explicit stored, returned, or static policy")

    def opaque_get_source(self, ctype: CType) -> str:
        # An output parameter cannot have a result-from clause. Conservatively
        # prohibit local origins at the source of the known shallow output copy.
        return ("escaping " if self.contains_reference(ctype) else "") + "object: ptr u8"

    def field_return(self, ctype: CType, rendered: str) -> str:
        origin = " from object" if self.contains_reference(ctype) else ""
        return f"(value: {rendered}{origin})"

    def render_enum(self, enum: EnumInfo) -> None:
        entry = self.enum_entries.get(enum.identity)
        context = entry.context if entry else f"enum dependency {enum.display_name!r}"
        for typedef_name in enum.typedef_names:
            self.ensure_typedef_unattributed(typedef_name, context)
        for item in enum.node.get("inner", []):
            if item.get("kind", "").endswith("Attr"):
                raise BindingError(f"{context}: enum packing or fixed-underlying attribute {item['kind']} is unsupported")
        underlying = self.enum_underlying(enum)
        name = self.landin_name_for_enum(enum)
        size, alignment = self.layout_of(underlying)
        if enum.c_name:
            self.c_assertions.extend([
                f'_Static_assert(__builtin_types_compatible_p({enum.c_name}, {self.c_type(underlying)}), "{enum.c_name} compatible type disagrees with its generated integer alias");',
                f'_Static_assert(sizeof({enum.c_name}) == {size}, "{enum.c_name} size disagrees with its generated integer alias");',
                f'_Static_assert(_Alignof({enum.c_name}) == {alignment}, "{enum.c_name} alignment disagrees with its generated integer alias");',
            ])
        lines = [f"public {name}: type = {self.landin_type(underlying)}"]
        constants: list[dict[str, Any]] = []
        for c_name, value in self.enum_values(enum):
            l_name = sanitize_landin(c_name)
            self._claim_landin(l_name, context + " constant")
            lines.append(f"public {l_name}: {name} = {value}")
            constants.append({"c_name": c_name, "landin_name": l_name, "value": value})
        self.ldn_type_blocks.append("\n".join(lines))
        self.metadata_declarations.append({
            "kind": "enum", "c_name": enum.c_name or None, "landin_name": name,
            "underlying_c_type": self.c_type(underlying), "representation": "integer-alias",
            "size": size, "alignment": alignment,
            "constants": constants, "selected": entry is not None,
        })

    def render_alias(self, name: str) -> None:
        self.ensure_typedef_unattributed(name, f"typedef {name!r}")
        ctype = self.types.alias(name)
        target = ctype.child
        self.ensure_supported(target, f"typedef {name!r}")  # type: ignore[arg-type]
        resolved = self.resolve_alias(target)  # type: ignore[arg-type]
        if resolved.kind in {"record", "enum", "callback"}:
            return
        landin_name = self.landin_name_for_alias(name)
        self.ldn_type_blocks.append(
            f"public {landin_name}: type = {self.landin_type(target, site=landin_name)}")
        self.metadata_declarations.append({
            "kind": "alias", "c_name": name, "landin_name": landin_name,
            "c_type": self.c_type(target), "representation": "type-alias",
            "selected": name in self.alias_entries,
        })

    def callback_annotation_maps(self, name: str, ctype: CType) -> tuple[dict[str, dict[str, Any]], dict[str, Any] | None]:
        entry = self.callback_entries.get(name)
        raw_params = entry.raw.get("parameters", {}) if entry else {}
        annotations: dict[str, dict[str, Any]] = {}
        actual = {f"argument_{index}" for index in range(1, len(ctype.parameters) + 1)}
        stale = sorted(set(raw_params) - actual)
        require(not stale, f"callback {name!r}: parameter {(stale[0] if stale else '<none>')!r} is absent (stale policy)")
        for index, parameter in enumerate(ctype.parameters, 1):
            p_name = f"argument_{index}"
            if self.contains_reference(parameter):
                require(p_name in raw_params,
                        f"callback {name!r} parameter {p_name!r}: missing required pointer policy")
                annotations[p_name] = validate_annotation(raw_params[p_name],
                                                          f"callback {name!r} parameter {p_name!r}")
                require(not (self.resolve_alias(parameter).kind == "callback" and
                             annotations[p_name]["nullability"] == "nullable"),
                        f"callback {name!r} parameter {p_name!r}: nested nullable callback is unsupported")
                require(annotations[p_name]["from"] == [],
                        f"callback {name!r} parameter {p_name!r}: from must be empty")
            else:
                require(p_name not in raw_params,
                        f"callback {name!r} parameter {p_name!r}: stale policy for non-reference value")
        result_annotation = None
        if self.contains_reference(ctype.result):  # type: ignore[arg-type]
            require(entry is not None and "result" in entry.raw,
                    f"callback {name!r} result: missing required pointer policy")
            result_annotation = validate_annotation(entry.raw["result"], f"callback {name!r} result")
            require(not (self.resolve_alias(ctype.result).kind == "callback" and
                         result_annotation["nullability"] == "nullable"),
                    f"callback {name!r} result: nested nullable callback is unsupported")
            unknown = sorted(set(result_annotation["from"]) - actual)
            require(not unknown, f"callback {name!r} result: from name {(unknown[0] if unknown else '<none>')!r} is absent")
            require(all(source in annotations for source in result_annotation["from"]),
                    f"callback {name!r} result: from must name reference-bearing parameters")
        elif entry is not None:
            require("result" not in entry.raw,
                    f"callback {name!r} result: stale policy for non-reference value")
        return annotations, result_annotation

    def render_callback(self, name: str) -> None:
        self.ensure_typedef_unattributed(name, f"callback {name!r}")
        alias = self.types.alias(name)
        callback = self.resolve_alias(alias)
        require(callback.kind == "callback", f"typedef {name!r} is not a callback")
        self.ensure_supported(alias, f"callback {name!r}")
        for index, parameter in enumerate(callback.parameters, 1):
            require(not self.opaque_by_value(parameter),
                    f"callback {name!r} parameter {index}: C-owned opaque by-value type is unsupported")
        require(not self.opaque_by_value(callback.result),  # type: ignore[arg-type]
                f"callback {name!r} result: C-owned opaque by-value type is unsupported")
        annotations, result_annotation = self.callback_annotation_maps(name, callback)
        l_name = self.landin_name_for_alias(name)
        parameters = [
            self.landin_parameter(value, f"argument_{index}", annotations.get(f"argument_{index}"),
                                  f"{l_name}_argument_{index}")
            for index, value in enumerate(callback.parameters, 1)
        ]
        if callback.variadic:
            parameters.append("...")
        result = self.landin_return(callback.result, result_annotation, f"{l_name}_result")  # type: ignore[arg-type]
        self.ldn_type_blocks.append(f"public {l_name}: type = extern(c) ({', '.join(parameters)}) -> {result}")
        entry = self.callback_entries.get(name)
        nullable = bool(entry and entry.raw["nullable"])
        callback_parameter_metadata = []
        for index, value in enumerate(callback.parameters, 1):
            argument_name = f"argument_{index}"
            callback_parameter_metadata.append({
                "c_name": argument_name,
                "landin_name": argument_name,
                "c_type": self.c_type(value),
                "landin_type": self.landin_type(
                    value, annotation=annotations.get(argument_name),
                    site=f"{l_name}_argument_{index}"),
                "policy": annotations.get(argument_name),
            })
        metadata: dict[str, Any] = {
            "kind": "callback", "c_name": name, "landin_name": l_name,
            "nullable_cell": nullable, "variadic": callback.variadic,
            "parameters": callback_parameter_metadata,
            "result": self.type_metadata(callback.result, result_annotation,  # type: ignore[arg-type]
                                         f"{l_name}_result"),
            "selected": entry is not None,
        }
        if nullable:
            require(not callback.variadic,
                    f"callback {name!r}: nullable variadic callback cell would require unsupported va_list forwarding")
            metadata["cell"] = self.render_callback_cell(name, l_name, callback, annotations,
                                                          result_annotation)
            metadata["adapter_output_escaping_sources"] = (
                list(result_annotation["from"]) if result_annotation else [])
        self.metadata_declarations.append(metadata)

    def render_callback_cell(self, c_name: str, l_name: str, callback: CType,
                             annotations: Mapping[str, Mapping[str, Any]],
                             result_annotation: Mapping[str, Any] | None) -> dict[str, str]:
        self.needs_stdlib = True
        stem = sanitize_landin(f"{l_name}_cell")
        optional = self.optional_for(stem, "ptr mut u8")
        struct_name = self.c_symbol(c_name, "cell_type")
        # c_symbol names are link-visible by default; a struct tag does not need
        # to consume the function-symbol namespace.
        self._c_symbols.remove(struct_name)
        self.callback_cell_structs[c_name] = struct_name
        self.c_definitions.append(f"struct {struct_name} {{ {c_name} value; }};")

        allocate = self.c_symbol(c_name, "cell_allocate")
        release = self.c_symbol(c_name, "cell_release")
        clear = self.c_symbol(c_name, "cell_clear")
        set_name = self.c_symbol(c_name, "cell_set")
        present = self.c_symbol(c_name, "cell_present")
        access = self.c_symbol(c_name, "cell_access")
        invoke = self.c_symbol(c_name, "cell_invoke")

        cell, value, output, *arguments = self.c_locals(
            "cell", "value", "result",
            *(f"argument_{index}" for index in range(1, len(callback.parameters) + 1)))
        self.add_c_function("void *", allocate, [],
                            [f"return calloc(1, sizeof(struct {struct_name}));"])
        self.add_c_function("void", release, [f"void *{cell}"], [f"free({cell});"])
        self.add_c_function("void", clear, [f"void *{cell}"],
                            [f"((struct {struct_name} *){cell})->value = 0;"])
        self.add_c_function("void", set_name, [f"void *{cell}", f"{c_name} {value}"],
                            [f"((struct {struct_name} *){cell})->value = {value};"])
        self.add_c_function("_Bool", present, [f"const void *{cell}"],
                            [f"return ((const struct {struct_name} *){cell})->value != 0;"])
        self.add_c_function(c_name, access, [f"const void *{cell}"], [
            f"{c_name} {value} = ((const struct {struct_name} *){cell})->value;",
            f"if ({value} == 0) __builtin_trap();",
            f"return {value};",
        ])

        invoke_params = [f"const void *{cell}"]
        call_args: list[str] = []
        ldn_invoke_params = ["cell: ptr u8"]
        output_sources = result_annotation["from"] if result_annotation else []
        for index, parameter in enumerate(callback.parameters, 1):
            arg = f"argument_{index}"
            local = arguments[index - 1]
            invoke_params.append(self.c_declarator(parameter, local))
            call_args.append(local)
            ldn_invoke_params.append(self.landin_parameter(
                parameter, arg, annotations.get(arg), f"{stem}_{arg}",
                output_store=arg in output_sources))
        result = self.resolve_alias(callback.result)  # type: ignore[arg-type]
        call = f"((const struct {struct_name} *){cell})->value({', '.join(call_args)})"
        if result.kind == "builtin" and result.name == "void":
            invoke_body = [f"if (((const struct {struct_name} *){cell})->value == 0) return 0;",
                           call + ";", "return 1;"]
        else:
            invoke_params.append(self.c_declarator(
                CType("pointer", self.c_type(callback.result) + " *", child=callback.result), output))  # type: ignore[arg-type]
            ldn_value_type = self.landin_type(callback.result, annotation=result_annotation,
                                              site=f"{stem}_invoke_result")  # type: ignore[arg-type]
            ldn_invoke_params.append(f"result: ptr mut {ldn_value_type}")
            invoke_body = [f"if (((const struct {struct_name} *){cell})->value == 0) return 0;",
                           f"*{output} = {call};", "return 1;"]
        self.add_c_function("_Bool", invoke, invoke_params, invoke_body)

        declarations = [
            self.ldn_extern(allocate, f"{stem}_allocate", [], f"(cell: {optional.name})"),
            self.ldn_extern(release, f"{stem}_release", ["cell: ptr mut u8"], "none"),
            self.ldn_extern(clear, f"{stem}_clear", ["cell: ptr mut u8"], "none"),
            self.ldn_extern(set_name, f"{stem}_set", ["cell: ptr mut u8", f"escaping value: {l_name}"], "none"),
            self.ldn_extern(present, f"{stem}_present", ["cell: ptr u8"], "(present: bool)"),
            self.ldn_extern(access, f"{stem}_access", ["cell: ptr u8"], f"(value: {l_name})"),
            self.ldn_extern(invoke, f"{stem}_invoke", ldn_invoke_params, "(invoked: bool)"),
        ]
        self.ldn_declarations.extend(declarations)
        return {"allocate": allocate, "release": release, "clear": clear, "set": set_name,
                "present": present, "access": access, "invoke": invoke}

    def add_c_function(self, result: str, name: str, parameters: list[str], body: list[str]) -> None:
        self.c_functions.append(CFunction(result, name, parameters, body))

    def ldn_extern(self, symbol: str, name: str, parameters: Sequence[str], result: str,
                   *, context: str | None = None) -> str:
        landin_name = sanitize_landin(name)
        owner = context or f"generated adapter {symbol!r}"
        previous = self._landin_names.get(landin_name)
        require(previous is None or previous == owner,
                f"{owner}: Landin name {landin_name!r} collides with {previous}")
        if previous is None:
            self._claim_landin(landin_name, owner)
        return (f"public extern(c) link(symbol: \"{symbol}\") {landin_name}: "
                f"({', '.join(parameters)}) -> {result}")

    def render_native_record(self, record: RecordInfo) -> None:
        name = self.landin_name_for_record(record)
        lines = [f"public {name}: type = layout(c) struct"]
        fields_metadata: list[dict[str, Any]] = []
        for index, field in enumerate(record.fields, 1):
            c_name = field["name"]
            annotation = self.annotations.get((record.identity, c_name))
            l_field = sanitize_landin(c_name)
            lines.append(f"    {l_field}: {self.landin_type(self.types.from_info(field['type']), annotation=annotation, site=f'{name}_{l_field}')}")
            fields_metadata.append({"c_name": c_name, "landin_name": l_field,
                                    "c_type": self.c_type(self.types.from_info(field["type"])),
                                    "policy": annotation})
        lines.append(f"end {name}")
        self.ldn_type_blocks.append("\n".join(lines))
        size, alignment, offsets = self.record_layout(record)
        c_type = record.c_name
        self.c_assertions.extend([
            f'_Static_assert(sizeof({c_type}) == {size}, "{c_type} size disagrees with Landin layout(c)");',
            f'_Static_assert(_Alignof({c_type}) == {alignment}, "{c_type} alignment disagrees with Landin layout(c)");',
        ])
        for field_name, offset in offsets:
            self.c_assertions.append(
                f'_Static_assert(__builtin_offsetof({c_type}, {field_name}) == {offset}, "{c_type}.{field_name} offset disagrees with Landin layout(c)");')
        entry = self.record_entries.get(record.identity)
        self.metadata_declarations.append({
            "kind": "record", "c_name": c_type, "landin_name": name,
            "representation": "native-layout-c", "size": size, "alignment": alignment,
            "fields": fields_metadata, "offsets": {key: value for key, value in offsets},
            "selected": entry is not None,
        })

    def render_opaque_record(self, record: RecordInfo) -> None:
        name = self.landin_name_for_record(record)
        entry = self.record_entries.get(record.identity)
        if not record.complete:
            self.ldn_type_blocks.append(
                f"-- {name} is an incomplete C-owned object; pointers to it are opaque byte pointers.")
            self.metadata_declarations.append({
                "kind": "record", "c_name": record.c_name, "landin_name": name,
                "representation": "incomplete-opaque", "selected": entry is not None,
            })
            return
        self.needs_stdlib = True
        optional = self.optional_for(f"{name}_object", "ptr mut u8")
        allocate = self.c_symbol(name, "allocate")
        release = self.c_symbol(name, "release")
        copy = self.c_symbol(name, "copy")
        size_name = self.c_symbol(name, "size")
        align_name = self.c_symbol(name, "alignment")
        c_type = record.c_name
        object_local, target_local, source_local = self.c_locals("object", "target", "source")
        record_type = CType("record", c_type, name=record.identity)
        self.add_c_function("void *", allocate, [], [f"return calloc(1, sizeof({c_type}));"])
        self.add_c_function("void", release, [f"void *{object_local}"], [f"free({object_local});"])
        self.add_c_function("void", copy, [f"void *{target_local}", f"const void *{source_local}"],
                            [f"*({c_type} *){target_local} = *(const {c_type} *){source_local};"])
        self.add_c_function("__SIZE_TYPE__", size_name, [], [f"return sizeof({c_type});"])
        self.add_c_function("__SIZE_TYPE__", align_name, [], [f"return _Alignof({c_type});"])
        self.ldn_declarations.extend([
            self.ldn_extern(allocate, f"{name}_allocate", [], f"(object: {optional.name})"),
            self.ldn_extern(release, f"{name}_release", ["object: ptr mut u8"], "none"),
            self.ldn_extern(copy, f"{name}_copy", ["target: ptr mut u8",
                            self.landin_opaque_parameter(record_type, "source",
                                output_store=self.contains_reference(record_type))], "none"),
            self.ldn_extern(size_name, f"{name}_size", [], "(size: usize)"),
            self.ldn_extern(align_name, f"{name}_alignment", [], "(alignment: usize)"),
        ])
        fields_metadata: list[dict[str, Any]] = []
        unnamed_index = 0
        for index, field in enumerate(record.fields, 1):
            field_type = self.types.from_info(field["type"])
            field_name = field.get("name")
            bit_width = None
            if field.get("isBitfield"):
                bit_width = self._bitfield_width(field)
            if not field_name:
                unnamed_index += 1
                fields_metadata.append({
                    "c_name": None, "bit_width": bit_width, "unnamed_index": unnamed_index,
                    "c_type": self.c_type(field_type), "accessors": {},
                })
                continue
            annotation = self.annotations.get((record.identity, field_name))
            accessors = self.render_opaque_field(record, name, field_name, field_type,
                                                  annotation, bit_width)
            fields_metadata.append({
                "c_name": field_name, "landin_name": sanitize_landin(field_name),
                "c_type": self.c_type(field_type), "bit_width": bit_width,
                "policy": annotation, "accessors": accessors,
            })
        self.metadata_declarations.append({
            "kind": "record", "c_name": c_type, "landin_name": name,
            "representation": "c-owned-opaque", "record_kind": "union" if record.union else "struct",
            "lifecycle": {"allocate": allocate, "release": release, "copy": copy,
                          "size": size_name, "alignment": align_name},
            "fields": fields_metadata, "selected": entry is not None,
        })

    @staticmethod
    def _bitfield_width(field: Mapping[str, Any]) -> int:
        for child in field.get("inner", []):
            if child.get("kind") == "ConstantExpr" and "value" in child:
                return int(child["value"], 0)
        raise BindingError("Clang AST bitfield has no constant width")

    def render_opaque_field(self, record: RecordInfo, record_name: str, field_name: str,
                            ctype: CType, annotation: Mapping[str, Any] | None,
                            bit_width: int | None) -> dict[str, str]:
        stem = f"{record_name}_{sanitize_landin(field_name)}"
        c_type = record.c_name
        object_local, value_local, index_local = self.c_locals("object", "value", "index")
        self.require_storable_policy(
            ctype, annotation, f"record {record.display_name!r} field {field_name!r}")
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "callback":
            require(self.callback_alias_name(ctype) is not None,
                    f"record {record.display_name!r} field {field_name!r}: opaque callback accessor requires a named function-pointer typedef")
        if resolved.kind == "array":
            get_name = self.c_symbol(stem, "get")
            set_name = self.c_symbol(stem, "set")
            element = resolved.child
            require(element is not None and resolved.count > 0, f"{stem}: invalid array field")
            element_resolved = self.resolve_alias(element)
            require(element_resolved.kind != "array",
                    f"record {record.display_name!r} field {field_name!r}: nested array accessor is unsupported")
            require(not (element_resolved.kind == "callback" and annotation and
                         annotation["nullability"] == "nullable"),
                    f"record {record.display_name!r} field {field_name!r}: nullable callback array accessor is unsupported")
            if self.opaque_by_value(element):
                self.add_c_function("void", get_name,
                                    [f"const void *{object_local}", f"__SIZE_TYPE__ {index_local}", f"void *{value_local}"], [
                                        f"if ({index_local} >= {resolved.count}) __builtin_trap();",
                                        f"*({self.c_type(element)} *){value_local} = ((const {c_type} *){object_local})->{field_name}[{index_local}];",
                                    ])
                self.add_c_function("void", set_name,
                                    [f"void *{object_local}", f"__SIZE_TYPE__ {index_local}", f"const void *{value_local}"], [
                                        f"if ({index_local} >= {resolved.count}) __builtin_trap();",
                                        f"(({c_type} *){object_local})->{field_name}[{index_local}] = *(const {self.c_type(element)} *){value_local};",
                                    ])
                self.ldn_declarations.extend([
                    self.ldn_extern(get_name, stem + "_get",
                                    [self.opaque_get_source(element), "index: usize", "value: ptr mut u8"], "none"),
                    self.ldn_extern(set_name, stem + "_set",
                                    ["object: ptr mut u8", "index: usize",
                                     self.landin_opaque_parameter(element, "value", annotation)], "none"),
                ])
                return {"get": get_name, "set": set_name}
            self.add_c_function(self.c_type(element), get_name,
                                [f"const void *{object_local}", f"__SIZE_TYPE__ {index_local}"], [
                                    f"if ({index_local} >= {resolved.count}) __builtin_trap();",
                                    f"return ((const {c_type} *){object_local})->{field_name}[{index_local}];",
                                ])
            self.add_c_function("void", set_name,
                                [f"void *{object_local}", f"__SIZE_TYPE__ {index_local}", self.c_declarator(element, value_local)], [
                                    f"if ({index_local} >= {resolved.count}) __builtin_trap();",
                                    f"(({c_type} *){object_local})->{field_name}[{index_local}] = {value_local};",
                                ])
            l_type = self.landin_type(element, annotation=annotation, site=stem + "_element")
            l_value_parameter = self.landin_parameter(
                element, "value", annotation, stem + "_element")
            self.ldn_declarations.extend([
                self.ldn_extern(get_name, stem + "_get", ["object: ptr u8", "index: usize"],
                                self.field_return(element, l_type)),
                self.ldn_extern(set_name, stem + "_set",
                                ["object: ptr mut u8", "index: usize", l_value_parameter], "none"),
            ])
            return {"get": get_name, "set": set_name}
        if resolved.kind == "callback" and annotation and annotation["nullability"] == "nullable":
            require(not resolved.variadic,
                    f"record {record.display_name!r} field {field_name!r}: nullable variadic callback requires unsupported va_list forwarding")
            clear = self.c_symbol(stem, "clear")
            set_name = self.c_symbol(stem, "set")
            present = self.c_symbol(stem, "present")
            access = self.c_symbol(stem, "access")
            self.add_c_function("void", clear, [f"void *{object_local}"],
                                [f"(({c_type} *){object_local})->{field_name} = 0;"])
            self.add_c_function("void", set_name,
                                [f"void *{object_local}", self.c_declarator(ctype, value_local)],
                                [f"(({c_type} *){object_local})->{field_name} = {value_local};"])
            self.add_c_function("_Bool", present, [f"const void *{object_local}"],
                                [f"return ((const {c_type} *){object_local})->{field_name} != 0;"])
            self.add_c_function(self.c_type(ctype), access, [f"const void *{object_local}"], [
                f"{self.c_declarator(ctype, value_local)} = ((const {c_type} *){object_local})->{field_name};",
                f"if ({value_local} == 0) __builtin_trap();", f"return {value_local};",
            ])
            l_type = self.landin_type(ctype, site=stem)
            l_value_parameter = self.landin_parameter(ctype, "value", annotation, stem)
            self.ldn_declarations.extend([
                self.ldn_extern(clear, stem + "_clear", ["object: ptr mut u8"], "none"),
                self.ldn_extern(set_name, stem + "_set", ["object: ptr mut u8", l_value_parameter], "none"),
                self.ldn_extern(present, stem + "_present", ["object: ptr u8"], "(present: bool)"),
                self.ldn_extern(access, stem + "_access", ["object: ptr u8"], self.field_return(ctype, l_type)),
            ])
            return {"clear": clear, "set": set_name, "present": present, "access": access}
        if self.opaque_by_value(ctype):
            get_name = self.c_symbol(stem, "get")
            set_name = self.c_symbol(stem, "set")
            nested = self.c_type(ctype)
            self.add_c_function("void", get_name, [f"const void *{object_local}", f"void *{value_local}"],
                                [f"*({nested} *){value_local} = ((const {c_type} *){object_local})->{field_name};"])
            self.add_c_function("void", set_name, [f"void *{object_local}", f"const void *{value_local}"],
                                [f"(({c_type} *){object_local})->{field_name} = *(const {nested} *){value_local};"])
            self.ldn_declarations.extend([
                self.ldn_extern(get_name, stem + "_get", [self.opaque_get_source(ctype), "value: ptr mut u8"], "none"),
                self.ldn_extern(set_name, stem + "_set",
                                ["object: ptr mut u8", self.landin_opaque_parameter(ctype, "value", annotation)], "none"),
            ])
            return {"get": get_name, "set": set_name}
        get_name = self.c_symbol(stem, "get")
        set_name = self.c_symbol(stem, "set")
        self.add_c_function(self.c_type(ctype), get_name, [f"const void *{object_local}"],
                            [f"return ((const {c_type} *){object_local})->{field_name};"])
        self.add_c_function("void", set_name,
                            [f"void *{object_local}", self.c_declarator(ctype, value_local)],
                            [f"(({c_type} *){object_local})->{field_name} = {value_local};"])
        l_type = self.landin_type(ctype, annotation=annotation, site=stem)
        l_value_parameter = self.landin_parameter(ctype, "value", annotation, stem)
        self.ldn_declarations.extend([
            self.ldn_extern(get_name, stem + "_get", ["object: ptr u8"], self.field_return(ctype, l_type)),
            self.ldn_extern(set_name, stem + "_set", ["object: ptr mut u8", l_value_parameter], "none"),
        ])
        return {"get": get_name, "set": set_name}

    def render_record(self, record: RecordInfo) -> None:
        classification = self.record_classification(record)
        if classification == "native-layout-c":
            self.render_native_record(record)
        else:
            self.render_opaque_record(record)

    def callback_alias_name(self, ctype: CType) -> str | None:
        if ctype.kind == "alias" and self.resolve_alias(ctype).kind == "callback":
            return ctype.name
        return None

    def require_nullable_cell(self, ctype: CType, context: str) -> str:
        alias = self.callback_alias_name(ctype)
        require(alias is not None,
                f"{context}: nullable callback requires a named function-pointer typedef")
        entry = self.callback_entries.get(alias)
        require(entry is not None and entry.raw["nullable"],
                f"{context}: callback typedef {alias!r} needs a selected nullable callback policy")
        self.needed_callbacks.add(alias)
        return alias

    def render_function(self, entry: PolicyEntry, node: dict[str, Any]) -> None:
        params, result = self.validate_function_shape(entry, node)
        annotations, result_annotation = self.validate_site_annotations(entry, params, result)
        variadic = bool(node.get("variadic"))
        if variadic:
            require(params, f"{entry.context}: C variadic declaration needs at least one fixed parameter")
        has_body = any(item.get("kind") == "CompoundStmt" for item in node.get("inner", []))
        storage_class = node.get("storageClass")
        if storage_class == "static":
            require(has_body,
                    f"{entry.context}: bodyless static function has no callable definition")
        require(not (node.get("inline") and storage_class != "static"),
                f"{entry.context}: external inline semantics are unsupported")
        wrapper_reasons: list[str] = []
        if storage_class == "static" or node.get("inline"):
            wrapper_reasons.append("internal-or-inline")
        for index, parameter in enumerate(params, 1):
            ctype = self.ctype_for_parameter(parameter)
            c_name = parameter.get("name") or f"argument_{index}"
            if self.opaque_by_value(ctype):
                wrapper_reasons.append(f"opaque-parameter:{c_name}")
            if self.resolve_alias(ctype).kind == "callback" and annotations.get(c_name, {}).get("nullability") == "nullable":
                self.require_nullable_cell(ctype, f"{entry.context} parameter {c_name!r}")
                wrapper_reasons.append(f"nullable-callback:{c_name}")
        if self.opaque_by_value(result):
            wrapper_reasons.append("opaque-result")
        if self.resolve_alias(result).kind == "callback" and result_annotation and result_annotation["nullability"] == "nullable":
            self.require_nullable_cell(result, f"{entry.context} result")
            wrapper_reasons.append("nullable-callback-result")
        direction = entry.raw["direction"]
        if direction == "export":
            require(storage_class != "static" and not node.get("inline") and not has_body,
                    f"{entry.context}: export must name an external bodyless declaration")
            require(not variadic,
                    f"{entry.context}: variadic export must use kind incoming_varargs")
            require(not wrapper_reasons,
                    f"{entry.context}: export requires a native C signature; adapter-required form {(wrapper_reasons[0] if wrapper_reasons else '<none>')} is unsupported")
            self.metadata_declarations.append({
                "kind": "function", "c_name": entry.name, "landin_name": entry.landin_name,
                "direction": "export", "variadic": variadic, "adapter": None,
                "parameters": self.function_parameter_metadata(params, annotations, entry.landin_name),
                "result": self.type_metadata(result, result_annotation, f"{entry.landin_name}_result"),
            })
            return
        require(not (variadic and wrapper_reasons),
                f"{entry.context}: adapter-required variadic call needs unsupported va_list forwarding ({wrapper_reasons[0] if wrapper_reasons else '<none>'})")

        c_parameter_decls: list[str] = []
        call_arguments: list[str] = []
        ldn_parameters: list[str] = []
        output_local, *argument_locals = self.c_locals(
            "result", *(f"argument_{index}" for index in range(1, len(params) + 1)))
        output_result = "opaque-result" in wrapper_reasons or "nullable-callback-result" in wrapper_reasons
        output_sources = list(result_annotation["from"]) if output_result and result_annotation else []
        parameter_landin_names = {
            sanitize_landin(parameter.get("name") or f"argument_{index}")
            for index, parameter in enumerate(params, 1)
        }
        output_landin_name = "result"
        while output_landin_name in parameter_landin_names:
            output_landin_name += "_"
        for index, parameter in enumerate(params, 1):
            ctype = self.ctype_for_parameter(parameter)
            c_name = parameter.get("name") or f"argument_{index}"
            local = argument_locals[index - 1]
            annotation = annotations.get(c_name)
            resolved = self.resolve_alias(ctype)
            if self.opaque_by_value(ctype):
                c_parameter_decls.append(f"const void *{local}")
                call_arguments.append(f"*(const {self.c_type(ctype)} *){local}")
                ldn_parameters.append(self.landin_opaque_parameter(
                    ctype, c_name, annotation, output_store=c_name in output_sources))
            elif resolved.kind == "callback" and annotation and annotation["nullability"] == "nullable":
                alias = self.require_nullable_cell(ctype, f"{entry.context} parameter {c_name!r}")
                struct_tag = self.callback_cell_structs[alias]
                c_parameter_decls.append(f"const void *{local}")
                call_arguments.append(f"((const struct {struct_tag} *){local})->value")
                escaping = self.escaping_prefix(ctype, annotation, output_store=c_name in output_sources)
                ldn_parameters.append(f"{escaping}{sanitize_landin(c_name)}: ptr u8")
            else:
                c_parameter_decls.append(self.c_declarator(ctype, local))
                call_arguments.append(local)
                ldn_parameters.append(self.landin_parameter(
                    ctype, c_name, annotation, f"{entry.landin_name}_{sanitize_landin(c_name)}",
                    output_store=c_name in output_sources))
        if variadic:
            ldn_parameters.append("...")

        link_symbol = entry.name
        ldn_result: str
        adapter: str | None = None
        if wrapper_reasons:
            adapter = self.c_symbol(entry.name, "call")
            link_symbol = adapter
            call = f"{entry.name}({', '.join(call_arguments)})"
            resolved_result = self.resolve_alias(result)
            if self.opaque_by_value(result):
                c_parameter_decls.insert(0, f"void *{output_local}")
                ldn_parameters.insert(0, f"{output_landin_name}: ptr mut u8")
                body = [f"*({self.c_type(result)} *){output_local} = {call};"]
                c_result = "void"
                ldn_result = "none"
            elif resolved_result.kind == "callback" and result_annotation and result_annotation["nullability"] == "nullable":
                alias = self.require_nullable_cell(result, f"{entry.context} result")
                struct_tag = self.callback_cell_structs[alias]
                c_parameter_decls.insert(0, f"void *{output_local}")
                ldn_parameters.insert(0, f"{output_landin_name}: ptr mut u8")
                body = [f"((struct {struct_tag} *){output_local})->value = {call};"]
                c_result = "void"
                ldn_result = "none"
            elif resolved_result.kind == "builtin" and resolved_result.name == "void":
                body = [call + ";"]
                c_result = "void"
                ldn_result = "none"
            else:
                body = [f"return {call};"]
                c_result = self.c_type(result)
                ldn_result = self.landin_return(result, result_annotation,
                                                 f"{entry.landin_name}_result")
            self.add_c_function(c_result, adapter, c_parameter_decls, body)
        else:
            ldn_result = self.landin_return(result, result_annotation,
                                             f"{entry.landin_name}_result")
        self.ldn_declarations.append(
            self.ldn_extern(link_symbol, entry.landin_name, ldn_parameters, ldn_result,
                            context=entry.context))
        self.metadata_declarations.append({
            "kind": "function", "c_name": entry.name, "landin_name": entry.landin_name,
            "direction": "import", "variadic": variadic, "adapter": adapter,
            "adapter_reasons": wrapper_reasons,
            "adapter_output_escaping_sources": output_sources,
            "parameters": self.function_parameter_metadata(params, annotations, entry.landin_name),
            "result": self.type_metadata(result, result_annotation, f"{entry.landin_name}_result"),
        })

    def type_metadata(self, ctype: CType, annotation: Mapping[str, Any] | None,
                      site: str) -> dict[str, Any]:
        resolved = self.resolve_alias(ctype)
        return {
            "c_type": self.c_type(ctype),
            "landin_type": None if resolved.kind == "builtin" and resolved.name == "void"
            else self.landin_type(ctype, annotation=annotation, site=site),
            "policy": dict(annotation) if annotation else None,
        }

    def function_parameter_metadata(self, params: Sequence[Mapping[str, Any]],
                                    annotations: Mapping[str, Mapping[str, Any]],
                                    site_prefix: str) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for index, parameter in enumerate(params, 1):
            c_name = parameter.get("name") or f"argument_{index}"
            ctype = self.ctype_for_parameter(parameter)
            result.append({
                "c_name": c_name, "landin_name": sanitize_landin(c_name),
                "c_type": self.c_type(ctype),
                "landin_type": self.landin_type(
                    ctype, annotation=annotations.get(c_name),
                    site=f"{site_prefix}_{sanitize_landin(c_name)}"),
                "policy": annotations.get(c_name),
            })
        return result

    def render_incoming_varargs(self, entry: PolicyEntry, node: dict[str, Any]) -> None:
        params, result = self.validate_function_shape(entry, node)
        require(bool(node.get("variadic")),
                f"{entry.context}: incoming_varargs must name a variadic header declaration")
        has_body = any(item.get("kind") == "CompoundStmt" for item in node.get("inner", []))
        require(node.get("storageClass") != "static" and not node.get("inline") and not has_body,
                f"{entry.context}: incoming_varargs must name an external bodyless declaration")
        require(params, f"{entry.context}: incoming varargs needs at least one fixed parameter")
        annotations, result_annotation = self.validate_site_annotations(entry, params, result)
        for index, parameter in enumerate(params, 1):
            c_name = parameter.get("name") or f"argument_{index}"
            resolved_parameter = self.resolve_alias(self.ctype_for_parameter(parameter))
            require(not (resolved_parameter.kind == "callback" and
                         annotations.get(c_name, {}).get("nullability") == "nullable"),
                    f"{entry.context} parameter {c_name!r}: nullable callback fixed parameter is unsupported for incoming varargs")
        resolved_result = self.resolve_alias(result)
        require(not (resolved_result.kind == "callback" and result_annotation and
                     result_annotation["nullability"] == "nullable"),
                f"{entry.context} result: nullable callback result is unsupported for incoming varargs")
        require(all(not self.opaque_by_value(self.ctype_for_parameter(parameter)) for parameter in params),
                f"{entry.context}: opaque fixed parameter is unsupported for incoming varargs")
        require(not self.opaque_by_value(result),
                f"{entry.context}: opaque result is unsupported for incoming varargs")
        names = [parameter.get("name") or f"argument_{index}"
                 for index, parameter in enumerate(params, 1)]
        handler_names = [sanitize_landin(name) for name in names]
        handler_names.extend(sanitize_landin(item["name"]) for item in entry.raw["schema"])
        require(len(handler_names) == len(set(handler_names)),
                f"{entry.context}: fixed and schema names collide after Landin normalization")
        count_name = entry.raw["count_parameter"]
        require(count_name in names,
                f"{entry.context}: count_parameter {count_name!r} is absent from header (stale policy)")
        count_type = self.resolve_alias(self.ctype_for_parameter(params[names.index(count_name)]))
        require(count_type.kind in {"builtin", "enum"} and
                not (count_type.kind == "builtin" and count_type.name in {"float", "double", "_Bool", "void"}),
                f"{entry.context}: count_parameter must have an integer type")

        allocated_locals = self.c_locals(
            *(f"fixed_{index}" for index in range(1, len(params) + 1)),
            *(f"tail_{index}" for index in range(1, len(entry.raw["schema"]) + 1)),
            "arguments")
        fixed_locals = allocated_locals[:len(params)]
        tail_locals = allocated_locals[len(params):-1]
        arguments_local = allocated_locals[-1]
        fixed_c_decls: list[str] = []
        fixed_calls: list[str] = []
        handler_c_decls: list[str] = []
        handler_ldn_params: list[str] = []
        for index, parameter in enumerate(params, 1):
            ctype = self.ctype_for_parameter(parameter)
            source_name = names[index - 1]
            local = fixed_locals[index - 1]
            fixed_c_decls.append(self.c_declarator(ctype, local))
            fixed_calls.append(local)
            handler_c_decls.append(self.c_prototype_parameter(ctype, source_name))
            handler_ldn_params.append(self.landin_parameter(
                ctype, source_name, annotations.get(source_name),
                f"{entry.landin_name}_{sanitize_landin(source_name)}"))

        schema_metadata: list[dict[str, Any]] = []
        tail_c_decls: list[str] = []
        tail_ldn_params: list[str] = []
        extraction: list[str] = []
        tail_calls: list[str] = []
        for index, item in enumerate(entry.raw["schema"], 1):
            promoted = item["promoted"]
            c_spelling = PROMOTED_TYPES[promoted]
            ctype = self.types.parse(c_spelling)
            tail_name = item["name"]
            annotation = None
            if promoted == "pointer":
                annotation = validate_annotation(item["policy"],
                                                 f"{entry.context} schema item {index}")
                require(annotation["from"] == [],
                        f"{entry.context} schema item {index}: from must be empty")
            local = tail_locals[index - 1]
            tail_c_decls.append(self.c_prototype_parameter(ctype, tail_name))
            tail_ldn_params.append(self.landin_parameter(
                ctype, tail_name, annotation, f"{entry.landin_name}_{sanitize_landin(tail_name)}"))
            extraction.append(f"{self.c_declarator(ctype, local)} = va_arg({arguments_local}, {self.c_type(ctype)});")
            tail_calls.append(local)
            schema_metadata.append({
                "name": tail_name, "promoted": promoted, "c_type": c_spelling,
                "landin_type": self.landin_type(ctype, annotation=annotation,
                                                 site=f"{entry.landin_name}_{tail_name}"),
                "policy": annotation,
            })
        self.needs_stdarg = True
        handler = entry.raw["handler"]
        handler_parameters = handler_c_decls + tail_c_decls
        handler_result = self.c_type(result)
        self.export_declarations.append(
            f"{handler_result} {handler}({', '.join(handler_parameters) if handler_parameters else 'void'});")
        count_local = fixed_locals[names.index(count_name)]
        body = [
            f"if ({count_local} != ({self.c_type(self.ctype_for_parameter(params[names.index(count_name)]))}){len(entry.raw['schema'])}) __builtin_trap();",
            f"va_list {arguments_local};",
            f"va_start({arguments_local}, {fixed_locals[-1]});",
        ]
        body.extend(extraction)
        body.append(f"va_end({arguments_local});")
        call = f"{handler}({', '.join(fixed_calls + tail_calls)})"
        resolved_result = self.resolve_alias(result)
        if resolved_result.kind == "builtin" and resolved_result.name == "void":
            body.append(call + ";")
        else:
            body.append("return " + call + ";")
        definition_params = fixed_c_decls + ["..."]
        self.add_c_function(handler_result, entry.name, definition_params, body)
        handler_type_name = self._claim_generated_landin(
            entry.landin_name + "_handler", entry.context + " handler type")
        ldn_return = self.landin_return(result, result_annotation,
                                        f"{entry.landin_name}_handler_result")
        self.ldn_type_blocks.append(
            f"public {handler_type_name}: type = extern(c) ({', '.join(handler_ldn_params + tail_ldn_params)}) -> {ldn_return}")
        self.metadata_declarations.append({
            "kind": "incoming_varargs", "c_name": entry.name,
            "landin_name": entry.landin_name, "handler": handler,
            "handler_type": handler_type_name, "count_parameter": count_name,
            "fixed_parameters": self.function_parameter_metadata(params, annotations, entry.landin_name),
            "schema": schema_metadata,
            "result": self.type_metadata(result, result_annotation, f"{entry.landin_name}_handler_result"),
        })

    def render_variable(self, entry: PolicyEntry, node: dict[str, Any]) -> None:
        attributes = [item.get("kind", "") for item in node.get("inner", [])
                      if item.get("kind", "").endswith("Attr")]
        require(not attributes,
                f"{entry.context}: unsupported variable attribute {(attributes[0] if attributes else '<none>')}")
        ctype = self.types.from_info(node["type"])
        self.ensure_supported(ctype, entry.context)
        annotation = None
        if self.contains_reference(ctype):
            require("value" in entry.raw, f"{entry.context}: value is missing required pointer policy")
            annotation = validate_annotation(entry.raw["value"], f"{entry.context} value")
            require(annotation["from"] == [], f"{entry.context} value: from must be empty")
        else:
            require("value" not in entry.raw,
                    f"{entry.context}: stale value policy for non-reference object")
        resolved = self.resolve_alias(ctype)
        if resolved.kind == "callback":
            require(self.callback_alias_name(ctype) is not None,
                    f"{entry.context}: callback object adapter requires a named function-pointer typedef")
        writable = entry.raw["writable"]
        if writable:
            self.require_storable_policy(ctype, annotation, entry.context + " value")
        require(not (writable and resolved.const), f"{entry.context}: const object cannot be writable")
        read_only = resolved.const or not writable
        storage = entry.raw["storage"]
        declarations = self.ast.variables.get(entry.name, [])
        require(all(value.get("storageClass") == "extern" for value in declarations),
                f"{entry.context}: variable policy requires only external header declarations")
        require(all("init" not in value for value in declarations),
                f"{entry.context}: initialized variable definition in a header is unsupported")
        if storage == "define":
            require(not resolved.const, f"{entry.context}: zero-initialized const definition is unsupported")
            if annotation:
                require(annotation["nullability"] == "nullable",
                        f"{entry.context}: zero-initialized pointer/callback definition must be nullable")
            tls = "_Thread_local " if node.get("tls") else ""
            self.c_definitions.append(f"{tls}{self.c_declarator(ctype, entry.name)};")
        tls = bool(node.get("tls"))
        stem = entry.landin_name
        address = self.c_symbol(entry.name, "address")
        read_name = self.c_symbol(entry.name, "read")
        write_name = self.c_symbol(entry.name, "write") if writable else None
        require(resolved.kind != "array",
                f"{entry.context}: array object adapters are unsupported")
        nullable_callback = (resolved.kind == "callback" and annotation is not None and
                             annotation["nullability"] == "nullable")
        opaque = self.opaque_by_value(ctype)
        extra_accessors: dict[str, str] = {}
        local_value, = self.c_locals("value")
        if nullable_callback:
            self.require_nullable_cell(ctype, f"{entry.context} value")
            clear_name = self.c_symbol(entry.name, "clear") if writable else None
            present_name = self.c_symbol(entry.name, "present")
            address_c_type = "const void *" if read_only else "void *"
            address_landin_type = "ptr u8" if read_only else "ptr mut u8"
            self.add_c_function(address_c_type, address, [],
                                [f"return ({address_c_type})&{entry.name};"])
            unqualified = dataclasses.replace(ctype, const=False)
            self.add_c_function(self.c_type(unqualified), read_name, [], [
                f"if ({entry.name} == 0) __builtin_trap();", f"return {entry.name};",
            ])
            if writable:
                self.add_c_function("void", write_name, [self.c_declarator(ctype, local_value)],  # type: ignore[arg-type]
                                    [f"{entry.name} = {local_value};"])
                self.add_c_function("void", clear_name, [], [f"{entry.name} = 0;"])  # type: ignore[arg-type]
            self.add_c_function("_Bool", present_name, [], [f"return {entry.name} != 0;"])
            l_callback = self.landin_type(ctype, site=stem + "_callback")
            self.ldn_declarations.extend([
                self.ldn_extern(address, stem + "_address", [], f"(address: {address_landin_type})"),
                self.ldn_extern(read_name, stem + "_read", [], f"(value: {l_callback})"),
                self.ldn_extern(present_name, stem + "_present", [], "(present: bool)"),
            ])
            if writable:
                l_callback_parameter = self.landin_parameter(
                    ctype, "value", annotation, stem + "_callback")
                self.ldn_declarations.extend([
                    self.ldn_extern(clear_name, stem + "_clear", [], "none"),  # type: ignore[arg-type]
                    self.ldn_extern(write_name, stem + "_write", [l_callback_parameter], "none"),  # type: ignore[arg-type]
                ])
            extra_accessors = {"clear": clear_name, "present": present_name}
        elif opaque:
            address_c_type = "const void *" if read_only else "void *"
            address_landin_type = "ptr u8" if read_only else "ptr mut u8"
            self.add_c_function(address_c_type, address, [],
                                [f"return ({address_c_type})&{entry.name};"])
            unqualified = dataclasses.replace(ctype, const=False)
            self.add_c_function("void", read_name, [f"void *{local_value}"],
                                [f"*({self.c_type(unqualified)} *){local_value} = {entry.name};"])
            if writable:
                self.add_c_function("void", write_name, [f"const void *{local_value}"],  # type: ignore[arg-type]
                                    [f"{entry.name} = *(const {self.c_type(unqualified)} *){local_value};"])
            self.ldn_declarations.extend([
                self.ldn_extern(address, stem + "_address", [], f"(address: {address_landin_type})"),
                self.ldn_extern(read_name, stem + "_read", ["value: ptr mut u8"], "none"),
            ])
            if writable:
                self.ldn_declarations.append(
                    self.ldn_extern(write_name, stem + "_write",
                                    [self.landin_opaque_parameter(ctype, "value", annotation)], "none"))  # type: ignore[arg-type]
        else:
            address_value_type = dataclasses.replace(ctype, const=True) if read_only else ctype
            pointer_to_value = CType("pointer", self.c_type(address_value_type) + " *",
                                     child=address_value_type)
            self.add_c_function(self.c_type(pointer_to_value), address, [], [f"return &{entry.name};"])
            unqualified = dataclasses.replace(ctype, const=False)
            self.add_c_function(self.c_type(unqualified), read_name, [], [f"return {entry.name};"])
            if writable:
                self.add_c_function("void", write_name, [self.c_declarator(ctype, local_value)],  # type: ignore[arg-type]
                                    [f"{entry.name} = {local_value};"])
            l_value = self.landin_type(ctype, annotation=annotation, site=stem + "_value")
            address_mutability = "" if read_only else "mut "
            self.ldn_declarations.extend([
                self.ldn_extern(address, stem + "_address", [],
                                f"(address: ptr {address_mutability}{l_value})"),
                self.ldn_extern(read_name, stem + "_read", [], f"(value: {l_value})"),
            ])
            if writable:
                l_value_parameter = self.landin_parameter(
                    ctype, "value", annotation, stem + "_value")
                self.ldn_declarations.append(
                    self.ldn_extern(write_name, stem + "_write", [l_value_parameter], "none"))  # type: ignore[arg-type]
        self.metadata_declarations.append({
            "kind": "variable", "c_name": entry.name, "landin_name": stem,
            "storage": storage, "thread_local": tls, "writable": writable,
            "c_type": self.c_type(ctype), "landin_type": "opaque-object" if opaque else
            self.landin_type(ctype, annotation=annotation, site=stem + "_value"),
            "policy": annotation,
            "accessors": {"address": address, "read": read_name, "write": write_name,
                          **extra_accessors},
        })

    def record_order(self) -> list[RecordInfo]:
        result: list[RecordInfo] = []
        visiting: set[str] = set()
        done: set[str] = set()

        def visit(identity: str) -> None:
            if identity in done:
                return
            require(identity not in visiting, "recursive by-value record dependency")
            visiting.add(identity)
            record = self.records_by_id[identity]
            if record.complete:
                for field in record.fields:
                    field_type = self.resolve_alias(self.types.from_info(field["type"]))
                    while field_type.kind == "array" and field_type.child:
                        field_type = self.resolve_alias(field_type.child)
                    if field_type.kind == "record" and field_type.name in self.needed_records:
                        visit(field_type.name)
            visiting.remove(identity)
            done.add(identity)
            result.append(record)

        for identity in sorted(self.needed_records,
                               key=lambda value: self.records_by_id[value].display_name):
            visit(identity)
        return result

    def _claim_dependency_landin(self, name: str, owner: str) -> None:
        previous = self._landin_names.get(name)
        require(previous is None or previous == owner,
                f"{owner}: Landin name {name!r} collides with {previous}")
        if previous is None:
            self._claim_landin(name, owner)

    def claim_dependency_names(self) -> None:
        for identity in sorted(self.needed_enums):
            enum = self.enums_by_id[identity]
            name = self.landin_name_for_enum(enum)
            entry = self.enum_entries.get(identity)
            owner = entry.context if entry else f"enum dependency {enum.display_name!r}"
            self._claim_dependency_landin(name, owner)
        for alias in sorted(self.needed_aliases | self.needed_callbacks):
            name = self.landin_name_for_alias(alias)
            entry = self.alias_entries.get(alias) or self.callback_entries.get(alias)
            owner = entry.context if entry else f"typedef dependency {alias!r}"
            self._claim_dependency_landin(name, owner)
        for identity in sorted(self.needed_records):
            record = self.records_by_id[identity]
            name = self.landin_name_for_record(record)
            entry = self.record_entries.get(identity)
            owner = entry.context if entry else f"record dependency {record.display_name!r}"
            self._claim_dependency_landin(name, owner)

    def generate(self) -> tuple[str, str, str, dict[str, Any]]:
        self.collect_dependencies()
        self.claim_dependency_names()
        for identity in sorted(self.needed_enums,
                               key=lambda value: self.landin_name_for_enum(self.enums_by_id[value])):
            self.render_enum(self.enums_by_id[identity])
        for name in sorted(self.needed_callbacks):
            self.render_callback(name)
        for name in sorted(self.needed_aliases):
            self.render_alias(name)
        for record in self.record_order():
            self.render_record(record)
        for entry, node in sorted(self.function_entries, key=lambda value: value[0].name):
            self.render_function(entry, node)
        for entry, node in sorted(self.variable_entries, key=lambda value: value[0].name):
            self.render_variable(entry, node)
        for entry, node in sorted(self.incoming_entries, key=lambda value: value[0].name):
            self.render_incoming_varargs(entry, node)

        optional_blocks = [f"public {value.absent}: atom\npublic {value.name}: type = {value.absent} | {value.member_type}"
                           for _, value in sorted(self.optional_types.items())]
        ldn_sections = [
            "-- Generated by bindings/generate.py; do not edit.",
            "-- landin/compiler is implicit and must not be imported.",
            "import core/c\n\ncompiler.assert(compiler.c_sysv_lp64)",
        ]
        if optional_blocks:
            ldn_sections.append("\n\n".join(optional_blocks))
        if self.ldn_type_blocks:
            ldn_sections.append("\n\n".join(self.ldn_type_blocks))
        if self.ldn_declarations:
            ldn_sections.append("\n\n".join(self.ldn_declarations))
        bindings = "\n\n".join(ldn_sections) + "\n"

        guard = f"LANDIN_{self.policy.namespace.upper()}_BINDINGS_H"
        export_lines = [
            "/* Generated by bindings/generate.py; do not edit. */",
            f"#ifndef {guard}", f"#define {guard}", "",
        ]
        export_lines.extend(f'#include "{header.logical}"' for header in self.headers)
        if self.headers:
            export_lines.append("")
        prototypes = [function.prototype() for function in self.c_functions]
        export_lines.extend(self.export_declarations)
        export_lines.extend(prototypes)
        export_lines.extend(("", f"#endif /* {guard} */"))
        exports = "\n".join(export_lines) + "\n"

        c_lines = ["/* Generated by bindings/generate.py; do not edit. */", '#include "exports.h"']
        if self.needs_stdarg:
            c_lines.append("#include <stdarg.h>")
        if self.needs_stdlib:
            c_lines.append("#include <stdlib.h>")
        if self.c_assertions:
            c_lines.extend(("", *self.c_assertions))
        if self.c_definitions:
            c_lines.extend(("", *self.c_definitions))
        if self.c_functions:
            c_lines.extend(("", "\n\n".join(function.definition() for function in self.c_functions)))
        adapters = "\n".join(c_lines) + "\n"

        declarations = sorted(self.metadata_declarations,
                              key=lambda item: (item["kind"], str(item.get("c_name")),
                                                item["landin_name"]))
        metadata: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "generator": GENERATOR_ID,
            "abi": {
                "target": SUPPORTED_TARGET, "calling_convention": "sysv-amd64",
                "data_model": "lp64", "byte_order": "little", "plain_char": "signed",
                "enum_policy": "clang-default-with-fno-short-enums",
            },
            "inputs": {
                "headers": [{"name": header.logical, "sha256": header.digest}
                            for header in self.headers],
                "policy_sha256": self.policy.digest,
            },
            "declarations": declarations,
            "outputs": {
                "bindings.ldn": sha256_bytes(bindings.encode("utf-8")),
                "adapters.c": sha256_bytes(adapters.encode("utf-8")),
                "exports.h": sha256_bytes(exports.encode("utf-8")),
            },
        }
        self.verify_rendered(bindings, adapters, exports, metadata)
        return bindings, adapters, exports, metadata

    def verify_rendered(self, bindings: str, adapters: str, exports: str,
                        metadata: Mapping[str, Any]) -> None:
        require("import landin/compiler" not in bindings,
                "internal: generated forbidden landin/compiler import")
        require("compiler.assert(compiler.c_sysv_lp64)" in bindings,
                "internal: generated bindings lost the ABI guard")
        require(len({function.name for function in self.c_functions}) == len(self.c_functions),
                "internal: duplicate generated C function")
        encoded = stable_json(metadata)
        json.loads(encoded)
        prohibited = [str(header.path) for header in self.headers]
        for path in prohibited:
            require(path not in bindings and path not in adapters and path not in exports and path not in encoded,
                    "internal: generated output contains an absolute input path")

def resolve_executable(value: str) -> pathlib.Path:
    found = shutil.which(value)
    require(found is not None, f"--clang executable {value!r} was not found")
    path = pathlib.Path(found).resolve()
    require(path.is_file() and os.access(path, os.X_OK),
            f"--clang {value!r} is not executable")
    return path


def existing_directory(value: str, option: str) -> pathlib.Path:
    path = pathlib.Path(value).expanduser().resolve()
    require(path.is_dir(), f"{option} {value!r} is not a directory")
    return path


def parse_arguments(argv: Sequence[str]) -> ToolInputs:
    parser = argparse.ArgumentParser(
        description="Generate Landin bindings and C adapters from external Clang AST JSON")
    parser.add_argument("--clang", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--sysroot", required=True)
    parser.add_argument("--header", action="append", required=True,
                        metavar="[LOGICAL=]PATH")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--include-dir", action="append", default=[])
    parser.add_argument("--system-include-dir", action="append", default=[])
    parser.add_argument("--define", action="append", default=[])
    args = parser.parse_args(argv)
    require(args.target == SUPPORTED_TARGET,
            f"--target must be exactly {SUPPORTED_TARGET!r}")
    clang = resolve_executable(args.clang)
    sysroot = existing_directory(args.sysroot, "--sysroot")
    headers: list[HeaderInput] = []
    logical_seen: set[str] = set()
    path_seen: set[pathlib.Path] = set()
    for raw in args.header:
        logical, path = parse_header_argument(raw)
        require(logical not in logical_seen, f"duplicate --header logical name {logical!r}")
        require(path not in path_seen, f"header path selected twice: {path}")
        logical_seen.add(logical)
        path_seen.add(path)
        try:
            content = path.read_bytes()
        except OSError as error:
            raise BindingError(f"cannot read --header {logical!r}: {error.strerror}") from error
        headers.append(HeaderInput(logical, path, sha256_bytes(content), content))
    include_dirs = [existing_directory(value, "--include-dir") for value in args.include_dir]
    system_include_dirs = [existing_directory(value, "--system-include-dir")
                           for value in args.system_include_dir]
    defines: list[str] = []
    define_names: set[str] = set()
    for value in args.define:
        require(bool(DEFINE.fullmatch(value)) and
                all(32 <= ord(character) != 127 for character in value),
                f"--define is not NAME or NAME=VALUE: {value!r}")
        name = value.split("=", 1)[0]
        require(name not in define_names, f"duplicate --define for {name!r}")
        define_names.add(name)
        defines.append(value)
    policy_path = pathlib.Path(args.policy).expanduser().resolve()
    require(policy_path.is_file(), f"--policy {args.policy!r} is not a regular file")
    out_dir = pathlib.Path(args.out_dir).expanduser().resolve()
    return ToolInputs(clang, args.target, sysroot, headers, include_dirs,
                      system_include_dirs, defines, policy_path, out_dir)


def create_include_map(directory: pathlib.Path, headers: Sequence[HeaderInput]) -> None:
    for header in headers:
        destination = directory / pathlib.PurePosixPath(header.logical)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(header.content)


def write_translation_unit(path: pathlib.Path, headers: Sequence[HeaderInput]) -> None:
    lines = ["/* Synthetic translation unit for Landin binding generation. */"]
    lines.extend(f'#include "{header.logical}"' for header in headers)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def preflight_output(directory: pathlib.Path) -> None:
    require(not directory.is_symlink(), "output directory must not be a symbolic link")
    require(not directory.exists() or directory.is_dir(),
            "output path exists and is not a directory")
    for name in OUTPUT_NAMES:
        entry = directory / name
        require(not entry.is_symlink() and (not entry.exists() or entry.is_file()),
                f"cannot publish {name}: existing output is not a regular file")


def publish_outputs(staging: pathlib.Path, directory: pathlib.Path) -> None:
    preflight_output(directory)
    existed = directory.exists()
    directory.mkdir(parents=True, exist_ok=True)
    backup = pathlib.Path(tempfile.mkdtemp(prefix=".landin-bindings-backup-",
                                         dir=directory.parent))
    previous: set[str] = set()
    replaced: list[str] = []
    keep_backup = False
    try:
        for name in OUTPUT_NAMES:
            if (directory / name).exists():
                shutil.copy2(directory / name, backup / name)
                previous.add(name)
        preflight_output(directory)
        try:
            for name in OUTPUT_NAMES:
                os.replace(staging / name, directory / name)
                replaced.append(name)
        except OSError as error:
            try:
                for name in reversed(replaced):
                    if name in previous:
                        os.replace(backup / name, directory / name)
                    else:
                        (directory / name).unlink()
                if not existed:
                    directory.rmdir()
            except OSError as rollback_error:
                keep_backup = True
                raise BindingError(
                    f"publication failed ({error.strerror}); rollback failed "
                    f"({rollback_error.strerror}); previous outputs retained in {backup}") from error
            raise BindingError(f"publication failed; previous outputs restored: {error.strerror}") from error
    finally:
        if not keep_backup:
            shutil.rmtree(backup)


def publish(inputs: ToolInputs) -> None:
    preflight_output(inputs.out_dir)
    policy = Policy.load(inputs.policy_path)
    require(policy.abi["target"] == inputs.target,
            "policy target disagrees with --target")
    parent = inputs.out_dir.parent
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="landin-bindings-", dir=parent) as raw_work:
        work = pathlib.Path(raw_work)
        include_map = work / "headers"
        include_map.mkdir()
        create_include_map(include_map, inputs.headers)
        translation = work / "translation.c"
        write_translation_unit(translation, inputs.headers)
        driver = ClangDriver(inputs, include_map)
        driver.verify_target()
        translation = driver.preprocess(translation)
        ast = ASTModel(driver.parse_ast(translation))
        generator = Generator(ast, policy, inputs.headers)
        generator.collect_dependencies()
        driver.query_enum_types(ast, translation,
                                [generator.enums_by_id[identity] for identity in
                                 sorted(generator.needed_enums, key=lambda value:
                                        generator.landin_name_for_enum(generator.enums_by_id[value]))])
        bindings, adapters, exports, metadata = generator.generate()
        metadata["inputs"]["defines"] = [
            {"name": value.split("=", 1)[0], "sha256": sha256_bytes(value.encode("utf-8"))}
            for value in inputs.defines
        ]
        staging = work / "output"
        staging.mkdir()
        (staging / "bindings.ldn").write_text(bindings, encoding="utf-8", newline="\n")
        (staging / "adapters.c").write_text(adapters, encoding="utf-8", newline="\n")
        (staging / "exports.h").write_text(exports, encoding="utf-8", newline="\n")
        (staging / "bindings.json").write_text(stable_json(metadata), encoding="utf-8", newline="\n")
        driver.validate_c(staging / "adapters.c", staging)
        # All validation, including adapter compilation, completes before any
        # destination file is replaced.
        publish_outputs(staging, inputs.out_dir)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        inputs = parse_arguments(sys.argv[1:] if argv is None else argv)
        publish(inputs)
    except (BindingError, OSError) as error:
        print(f"bindings: error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
