#!/usr/bin/env -S rdmd -version=MindyscriptEmulatorAppMain
/+
	== mindyscript – Minimal D script interpreter ==
	Copyright Mindy Batek (0xEAB) 2026.
	Distributed under the Boost Software License, Version 1.0.
 +/
/+
	Quickstart

	- dmd     -version=MindyscriptEmulatorAppMain -run mindyscript.d
	- ldc2 --d-version=MindyscriptEmulatorAppMain -run mindyscript.d
	- rdmd    -version=MindyscriptEmulatorAppMain      mindyscript.d
	- ./mindyscript.d
 +/
/+
	Run unittests

	- dmd  -unittest -main -g -run mindyscript.d
	- ldc2 -unittest -main -g -run mindyscript.d
	- rdmd -unittest -main -g      mindyscript.d
 +/
module arsd.mindyscript;

import std.array : appender;
import std.conv : to;
import std.math : round;
import std.meta;
static import std.sumtype;
static import std.typecons;

// === Commons =================================================================

private {
	alias string = const(char)[];
	alias istring = object.string;

	alias match = std.sumtype.match;
	alias get = std.sumtype.get;
}

abstract class MindyscriptException : Exception {
@safe pure nothrow @nogc:
	private this(istring message, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(message, file, line, next);
	}
}

class InvalidArgumentException(T) : MindyscriptException {

	public {
		istring argumentName;
		istring details;
		T badValue;
	}

@safe pure nothrow:
	private this(
		istring argumentName,
		istring details,
		T badValue,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null
	) {
		this.argumentName = argumentName;
		this.details = details;
		this.badValue = badValue;

		const msg = "Invalid argument `" ~ argumentName ~ "` (=`" ~ badValue.to!istring() ~ "`): " ~ details;
		super(msg, file, line, next);
	}
}

class ArgumentOutOfRangeException(T) : InvalidArgumentException!T {

	public {
		T minValue;
		T maxValue;
		bool maxValueIsExclusive;
	}

@safe pure nothrow:
	private this(
		istring argumentName,
		istring details,
		T badValue,
		T minValue,
		T maxValue,
		bool maxValueIsExclusive = true,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null
	) {
		this.minValue = minValue;
		this.maxValue = maxValue;
		this.maxValueIsExclusive = maxValueIsExclusive;

		if (details.length > 0) {
			details ~= "\n";
		}
		const rangeEnd = (this.maxValueIsExclusive) ? ")" : "]";
		details ~= "Value range: ["
			~ "`" ~ this.minValue.to!istring() ~ "`, "
			~ "`" ~ this.maxValue.to!istring() ~ "`" ~ rangeEnd;

		super(argumentName, details, badValue, file, line, next);
	}
}

// === File + Location Handling ================================================

struct Location {
	string file = null;
	ptrdiff_t offset = -1;
}

struct LocationHumanReadable {
	public {
		string file = null;
		ptrdiff_t line = -1;
	}

@safe:

	public this(string file, ptrdiff_t line) {
		this.file = file;
		this.line = line;
	}

	static typeof(this) fromLocation(const Location location, string sourceCode) @trusted {
		auto result = typeof(this)(location.file, 0);

		if (location.offset < 0) {
			static immutable msg = "Invalid location offset.";
			throw new InvalidArgumentException!ptrdiff_t("location", msg, location.offset);
		}
		if (location.offset > sourceCode.length) {
			static immutable msg = "`location.offset` must not exceed `sourceCode.length`.";
			throw new ArgumentOutOfRangeException!ptrdiff_t(
				`location.offset`,
				msg,
				location.offset,
				0,
				cast(ptrdiff_t) sourceCode.length,
			);
		}

		bool prevWasCR = false;
		foreach (c; sourceCode[0 .. location.offset]) {
			if (c == '\x0D') {
				++result.line;
				prevWasCR = true;
				continue;
			}

			if (c == '\x0A') {
				if (!prevWasCR) {
					++result.line;
				}
			}

			prevWasCR = false;
		}

		return result;
	}

	istring toString() const @safe pure nothrow {
		if (file is null) {
			return line.to!istring();
		}

		return file ~ "(" ~ line.to!istring() ~ ")";
	}
}

interface LocationException {
	Location location() const @safe pure nothrow @nogc;
}

private mixin template LocationProperty(alias loc) {
	Location location() const @safe pure nothrow @nogc => loc;
}

// === Type System =============================================================

alias Variable = std.sumtype.SumType!(
	typeof(null),
	bool,
	char,
	float,
	int,
);

struct VMVoid {
}

alias ReturnValue = std.sumtype.SumType!(Variable, VMVoid);

enum isVariableType(T) = (staticIndexOf!(T, Variable.Types) >= 0);

final class LiteralParserException : MindyscriptException {
	string rawValue;

	private this(
		string rawValue,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null,
	) @safe {
		this.rawValue = rawValue;
		super("Bad literal value.", file, line, next);
	}
}

Variable parseLiteral(T)(string rawValue) @safe if (isVariableType!T) {
	try {
		return Variable(rawValue.to!T());
	}
	catch (Exception ex) {
		throw new LiteralParserException(rawValue, __FILE__, __LINE__, ex);
	}

	assert(false, "unreachable");
}

// === ISA =====================================================================

alias RegisterID = size_t;

alias Registers = Variable[];

struct BinaryOperationRegisterIDs {
	/// Destination register
	RegisterID dst;

	/// Left-hand side register
	RegisterID lhs;

	/// Right-hand side register
	RegisterID rhs;
}

private pragma(inline, true) void executeOperator(string op)(
	Registers registers,
	BinaryOperationRegisterIDs registerIDs,
) @safe {
	match!(
		(typeof(null) lhs, typeof(null) rhs) { registers[registerIDs.dst] = null; },
		(typeof(null) lhs, rhs) { registers[registerIDs.dst] = null; },
		(lhs, typeof(null) rhs) { registers[registerIDs.dst] = null; },
		(lhs, rhs) { registers[registerIDs.dst] = mixin(op); },
	)(registers[registerIDs.lhs], registers[registerIDs.rhs]);
}

private BinaryOperationRegisterIDs parseBinaryOperation(
	ref AssemblyInstructionArgumentsParser argsParser,
	ref Assembler.State state,
) @safe {
	argsParser.setupConstraints(3, 3);

	BinaryOperationRegisterIDs result;

	argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
	result.dst = state.addOrResolveRegister(argsParser.front.data);
	argsParser.popFront();

	argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
	result.lhs = state.addOrResolveRegister(argsParser.front.data);
	argsParser.popFront();

	argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
	result.rhs = state.addOrResolveRegister(argsParser.front.data);
	argsParser.popFront();

	return result;
}

private enum JumpInstructionRegisterCount {
	none = 0,
	single = 1,
	binary = 2,
}

private void parseJumpInstruction(InstructionType)(
	ref AssemblyInstructionArgumentsParser argsParser,
	ref Assembler.State state,
) @safe {
	static if (__traits(hasMember, InstructionType, "targetLocation")) {
		alias TargetLocation = typeof(__traits(getMember, InstructionType, "targetLocation"));

		static if (__traits(hasMember, InstructionType, "subject")) {
			static assert(!__traits(hasMember, InstructionType, "lhs"));
			static assert(!__traits(hasMember, InstructionType, "rhs"));
			enum expectedArgCount = 2;
		}
		else static if (__traits(hasMember, InstructionType, "lhs")) {
			static assert(__traits(hasMember, InstructionType, "rhs"));
			enum expectedArgCount = 3;
		}
		else {
			enum expectedArgCount = 1;
		}
	}
	else {
		enum expectedArgCount = 0;
	}

	argsParser.setupConstraints(expectedArgCount, expectedArgCount);

	static if (expectedArgCount == 0) {
		state.ir ~= Instruction(InstructionType());
	}

	static if (expectedArgCount >= 1) {
		argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier, AssemblyToken.Type.literalInteger);

		TargetLocation targetLocation;

		if (argsParser.front.type == AssemblyToken.Type.identifier) {
			const labelID = argsParser.front.data;
			const location = argsParser.front.location;
			argsParser.popFront();

			state.requestLabelForUpcomingInstruction(labelID, location);
			targetLocation = TargetLocation.max;
		}
		else if (argsParser.front.type == AssemblyToken.Type.literalInteger) {
			targetLocation = parseLiteral(argsParser.front).get!int;
			if (targetLocation < 0) {
				static immutable msg = "Invalid target offset: Absolute value cannot be negative.";
				throw new AssemblerException(msg, argsParser.front.location);
			}

			argsParser.popFront();
		}
		else {
			assert(false, "unreachable");
		}
	}

	static if (expectedArgCount == 1) {
		state.ir ~= Instruction(InstructionType(targetLocation));
	}

	static if (expectedArgCount >= 2) {
		argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
		const lhs = state.addOrResolveRegister(argsParser.front.data);
		argsParser.popFront();
	}

	static if (expectedArgCount == 2) {
		state.ir ~= Instruction(InstructionType(targetLocation, lhs));
	}

	static if (expectedArgCount >= 3) {
		argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
		const rhs = state.addOrResolveRegister(argsParser.front.data);
		argsParser.popFront();
	}

	static if (expectedArgCount == 3) {
		state.ir ~= Instruction(InstructionType(targetLocation, lhs, rhs));
	}
}

/++
	Instruction Set Architecture
 +/
struct ISA {
	@disable this();

	private struct Op {
		istring id;
	}

	private struct Jump;

	@Op("add")
	struct AddInstruction {
		BinaryOperationRegisterIDs registerIDs;

		void execute(Registers rg) const @safe {
			executeOperator!"lhs + rhs"(rg, registerIDs);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			const registerIDs = parseBinaryOperation(argsParser, state);
			state.ir ~= Instruction(typeof(this)(registerIDs));
		}
	}

	@Op("div")
	struct DivideInstruction {
		BinaryOperationRegisterIDs registerIDs;

		void execute(Registers rg) const @safe {
			executeOperator!"lhs / rhs"(rg, registerIDs);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			const registerIDs = parseBinaryOperation(argsParser, state);
			state.ir ~= Instruction(typeof(this)(registerIDs));
		}
	}

	@Op("jal")
	@Jump
	struct JumpAlwaysInstruction {
		size_t targetLocation;

		void execute(ref size_t programCounter) const @safe {
			programCounter = targetLocation;
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			return parseJumpInstruction!(typeof(this))(argsParser, state);
		}
	}

	@Op("jnz")
	@Jump
	struct JumpIfNotZeroInstruction {
		size_t targetLocation;
		RegisterID subject;

		bool execute(Registers rg, ref size_t programCounter) const @safe {
			const subjectValue = rg[subject];
			const shallJump = subjectValue.match!(
				value => (value != 0),
				(typeof(null) value) => false,
			);

			if (shallJump) {
				programCounter = targetLocation;
				return true;
			}

			return false;
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			return parseJumpInstruction!(typeof(this))(argsParser, state);
		}
	}

	@Op("jz")
	@Jump
	struct JumpIfZeroInstruction {
		size_t targetLocation;
		RegisterID subject;

		bool execute(Registers rg, ref size_t programCounter) const @safe {
			const subjectValue = rg[subject];
			const shallJump = subjectValue.match!(
				value => (value == 0),
				(typeof(null) value) => true,
			);

			if (shallJump) {
				programCounter = targetLocation;
				return true;
			}

			return false;
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			return parseJumpInstruction!(typeof(this))(argsParser, state);
		}
	}

	@Op("ldi")
	struct LoadImmediateInstruction {
		RegisterID destination;
		Variable value;

		void execute(Registers rg) const @safe {
			rg[destination] = value;
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			argsParser.setupConstraints(2, 2);
			argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
			const registerDestination = state.addOrResolveRegister(argsParser.front.data);
			argsParser.popFront();

			const valueToLoad = parseLiteral(argsParser.front);
			argsParser.popFront();

			state.ir ~= Instruction(LoadImmediateInstruction(registerDestination, valueToLoad));
		}
	}

	@Op("mod")
	struct ModuloInstruction {
		BinaryOperationRegisterIDs registerIDs;

		void execute(Registers rg) const @safe {
			executeOperator!"lhs % rhs"(rg, registerIDs);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			const registerIDs = parseBinaryOperation(argsParser, state);
			state.ir ~= Instruction(typeof(this)(registerIDs));
		}
	}

	@Op("mov")
	struct MoveInstruction {
		RegisterID dst;
		RegisterID src;

		void execute(Registers rg) const @safe {
			rg[dst] = rg[src];
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			argsParser.setupConstraints(2, 2);

			argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
			const registerDst = state.addOrResolveRegister(argsParser.front.data);
			argsParser.popFront();

			argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
			const registerSrc = state.addOrResolveRegister(argsParser.front.data);
			argsParser.popFront();

			state.ir ~= Instruction(typeof(this)(registerDst, registerSrc));
		}
	}

	@Op("mul")
	struct MultiplyInstruction {
		BinaryOperationRegisterIDs registerIDs;

		void execute(Registers rg) const @safe {
			executeOperator!"lhs * rhs"(rg, registerIDs);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			const registerIDs = parseBinaryOperation(argsParser, state);
			state.ir ~= Instruction(typeof(this)(registerIDs));
		}
	}

	@Op("nop")
	struct NoOpInstruction {
		void execute() const @safe {
			return; // Do nothing.
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			argsParser.setupConstraints(0, 0);
		}
	}

	@Op("print")
	struct PrintInstruction {
		RegisterID a;

		void execute(Registers reg) const @safe {
			import std.stdio : writeln;

			writeln(reg[a]);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			argsParser.setupConstraints(1, 1);

			argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
			const registerID = state.addOrResolveRegister(argsParser.front.data);
			argsParser.popFront();

			state.ir ~= Instruction(PrintInstruction(registerID));
		}
	}

	@Op("ret")
	struct ReturnInstruction {
		RegisterID a;
		bool returnVoid;

		ReturnValue execute(Registers rg) const @safe {
			if (returnVoid) {
				return ReturnValue(VMVoid());
			}

			return ReturnValue(rg[a]);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			argsParser.setupConstraints(0, 1);

			// RET void
			if (argsParser.empty) {
				state.ir ~= Instruction(ReturnInstruction(RegisterID.max, true));
				return;
			}

			argsParser.throwIfUnexpectedTokenType(AssemblyToken.Type.identifier);
			const registerID = state.addOrResolveRegister(argsParser.front.data);
			argsParser.popFront();

			state.ir ~= Instruction(ReturnInstruction(registerID, false));
		}
	}

	@Op("sub")
	struct SubtractInstruction {
		BinaryOperationRegisterIDs registerIDs;

		void execute(Registers rg) const @safe {
			executeOperator!"lhs - rhs"(rg, registerIDs);
		}

		static void parse(ref AssemblyInstructionArgumentsParser argsParser, ref Assembler.State state) @safe {
			const registerIDs = parseBinaryOperation(argsParser, state);
			state.ir ~= Instruction(typeof(this)(registerIDs));
		}
	}

	template InstructionsSeq() {
		import std.traits : getSymbolsByUDA;

		alias InstructionsSeq = getSymbolsByUDA!(ISA, ISA.Op);
	}
}

alias Instruction = std.sumtype.SumType!(ISA.InstructionsSeq!());

template idOf(Instruction) {
	import std.traits : getUDAs;

	static assert(getUDAs!(Instruction, ISA.Op).length == 1, "Instruction must have one single `@Op`.");
	enum istring idOf = getUDAs!(Instruction, ISA.Op)[0].id;
}

struct Program {
	Instruction[] ir;
	RegisterID registerCount;
}

// === Assembler ===============================================================

struct AssemblyToken {
	enum Type {
		error,
		eof,

		shebang,

		whitespace,
		linebreak,

		colon,
		comma,
		comment,
		identifier,

		literalBoolean,
		literalCharacter,
		literalFloatingPoint,
		literalInteger,
		literalString,
	}

	Type type;
	string data;
	Location location;
}

Variable parseLiteral(AssemblyToken token) @safe {
	try {
		switch (token.type) {
		case AssemblyToken.Type.literalBoolean:
			return parseLiteral!bool(token.data);

		case AssemblyToken.Type.literalCharacter:
			return parseLiteral!char(token.data[1 .. 2]);

		case AssemblyToken.Type.literalFloatingPoint:
			return parseLiteral!float(token.data);

		case AssemblyToken.Type.literalInteger:
			return parseLiteral!int(token.data);

		case AssemblyToken.Type.literalString:
			// TODO: implement
			assert(false, "Not implemented.");

		default:
			throw new AssemblerUnexpectedTokenException(token.type, [
				AssemblyToken.Type.literalBoolean,
				AssemblyToken.Type.literalCharacter,
				AssemblyToken.Type.literalFloatingPoint,
				AssemblyToken.Type.literalInteger,
				AssemblyToken.Type.literalString,
			], token.location);
		}
	}
	catch (Exception ex) {
		throw new AssemblerException("Cannot parse invalid literal value.", token.location, __FILE__, __LINE__, ex);
	}
}

class AssemblerException : MindyscriptException, LocationException {
	private Location _location;
	mixin LocationProperty!_location;

	this(
		istring message,
		Location location,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null,
	) @safe {
		_location = location;
		super(message, file, line, next);
	}
}

class AssemblyLexerException : AssemblerException {
	this(
		istring message,
		Location location,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null,
	) @safe {
		super(
			message,
			location,
			file, line, next,
		);
	}
}

struct AssemblyLexer {
	import std.ascii;

	private {
		alias Token = AssemblyToken;

		string _sourceFile;
		string _source;
		ptrdiff_t _offset;
		Token _front = Token(Token.Type.eof, null);
	}

@safe:

	this(string sourceCode, string sourceFile) {
		_source = sourceCode;
		_sourceFile = sourceFile;
		_offset = 0;
		this.popFront();
	}

	bool empty() const => _front.type == Token.Type.eof;
	AssemblyToken front() const => _front;

	private Location makeLocation(ptrdiff_t additionalOffset = 0) {
		const offset = _offset + additionalOffset;
		return Location(_sourceFile, offset);
	}

	private void makeToken(Token.Type type, size_t length) {
		const location = this.makeLocation();
		_front = Token(type, _source[0 .. length], location);
		_source = _source[length .. $];
		_offset += length;
	}

	private void lexHash() {
		// shebang
		if ((_source.length >= 2) && (_source[1] == '!')) {
			foreach (idx, c; _source[2 .. $]) {
				if ((c == '\n') || (c == '\r')) {
					return this.makeToken(Token.Type.shebang, 2 + idx);
				}
			}

			return this.makeToken(Token.Type.shebang, _source.length);
		}

		// TODO: implement
		assert(false, "Not implemented.");
	}

	private size_t scanRawIdentifier() {
		foreach (size_t idx, char c; _source) {
			if (c.isAlphaNum || (c == '_')) {
				continue;
			}

			if (c.isWhite || (c == ',') || (c == ':')) {
				return idx;
			}

			throw new AssemblyLexerException(
				"Unexpected character `" ~ c ~ "` in identifier.",
				this.makeLocation(idx),
			);
		}

		return _source.length;
	}

	private void lexIdentifier() {
		const length = this.scanRawIdentifier();
		const data = _source[0 .. length];

		Token.Type type;

		switch (data) {
		case "false":
		case "true":
			type = Token.Type.literalBoolean;
			break;

		default:
			type = Token.Type.identifier;
			break;
		}

		this.makeToken(type, length);
	}

	private void lexDecimalLiteral() {
		bool floatingPoint = false;

		foreach (size_t idx, char c; _source) {
			if (c.isDigit || c == '_') {
				continue;
			}

			if (c == '.') {
				if (floatingPoint) {
					throw new AssemblyLexerException(
						"Duplicate decimal point in numeric literal.",
						this.makeLocation(idx),
					);
				}

				floatingPoint = true;
				continue;
			}

			if (c.isWhite) {
				const type = (floatingPoint) ? Token.Type.literalFloatingPoint : Token.Type.literalInteger;
				return makeToken(type, idx);
			}

			throw new AssemblyLexerException(
				"Unexpected character in numeric literal.",
				this.makeLocation(idx),
			);
		}

		const type = (floatingPoint) ? Token.Type.literalFloatingPoint : Token.Type.literalInteger;
		return makeToken(type, _source.length);
	}

	private void lexNumericLiteral() {
		if ((_source[0] == '0') && (_source.length >= 2)) {
			if (_source[1] == 'x') {
				// TODO: hex literals
			}

			if (_source[1] == 'b') {
				// TODO: binary literals
			}

			if (_source[1] == 'o') {
				// TODO: octal literals
				throw new AssemblyLexerException(
					"Octal literals are not supported.",
					this.makeLocation(),
				);
			}
		}

		return this.lexDecimalLiteral();
	}

	private void lexWhitespace() {
		foreach (size_t idx, char c; _source) {
			if (
				(c == '\x09') ||
				(c == '\x0B') ||
				(c == '\x0C') ||
				(c == '\x20')) {
				continue;
			}

			return this.makeToken(Token.Type.whitespace, idx);
		}

		return this.makeToken(Token.Type.whitespace, _source.length);
	}

	void popFront() {
		if (_source.length == 0) {
			_front = Token(Token.Type.eof, null);
			return;
		}

		switch (_source[0]) {
		case '\x00': .. case '\x08':
			this.makeToken(Token.Type.error, 1);
			break;

		case '\x0A':
			this.makeToken(Token.Type.linebreak, 1);
			break;

		case '\x0B':
		case '\x0C':
			this.lexWhitespace();
			break;

		case '\x0D':
			if ((_source.length >= 2) && (_source[1] == '\x0A')) {
				this.makeToken(Token.Type.linebreak, 2);
				break;
			}
			this.makeToken(Token.Type.linebreak, 1);
			break;

		case '#':
			this.lexHash();
			break;

		case ' ':
			this.lexWhitespace();
			break;

		case ',':
			this.makeToken(Token.Type.comma, 1);
			break;

		case '0': .. case '9':
			this.lexNumericLiteral();
			break;

		case ':':
			this.makeToken(Token.Type.colon, 1);
			break;

		case 'A': .. case 'Z':
		case '_':
		case 'a': .. case 'z':
			this.lexIdentifier();
			break;

		case '\x80': .. case '\xFF':
			this.makeToken(Token.Type.error, 1);
			break;

		default:
			throw new AssemblyLexerException("Unexpected character.", this.makeLocation());
		}
	}
}

void popWhitespace(ref AssemblyLexer lexer) @safe {
	while (!lexer.empty) {
		if (lexer.front.type != AssemblyToken.Type.whitespace) {
			return;
		}

		lexer.popFront();
	}
}

void popLinebreakEquiv(ref AssemblyLexer lexer) @safe {
	lexer.popWhitespace();

	if (lexer.empty) {
		return;
	}

	if (lexer.front.type != AssemblyToken.Type.linebreak) {
		throw new AssemblerException("Unexpected token type; line-break expected.", lexer.front.location);
	}

	lexer.popFront();
}

struct AssemblyStatementLexer {
	private {
		bool _empty = true;
		AssemblyLexer _lexer;
	}

@safe:

	this(AssemblyLexer lexer) {
		_lexer = lexer;
		_empty = false;
	}

	AssemblyLexer wrappedLexer() inout => _lexer;

	bool empty() const => _empty;

	AssemblyToken front() inout => _lexer.front;

	void popFront() {
		_lexer.popFront();
		this.skip();
	}

	private void skip() {
		while (!_lexer.empty) {
			switch (_lexer.front.type) {
			case AssemblyToken.Type.comment:
			case AssemblyToken.Type.whitespace:
				break;

			case AssemblyToken.Type.eof:
			case AssemblyToken.Type.linebreak:
				_empty = true;
				return;

			default:
				return;
			}

			_lexer.popFront();
		}

		if (_lexer.empty) {
			_empty = true;
		}
	}
}

class AssemblerUnexpectedTokenException : AssemblerException {
	AssemblyToken.Type got;
	const(AssemblyToken.Type)[] expected;

	this(
		AssemblyToken.Type got,
		const(AssemblyToken.Type)[] expected,
		Location location,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null,
	) @safe
	in (expected.length >= 1) {
		this.got = got;
		this.expected = expected;

		auto msg = appender!istring();
		msg ~= "Unexpected `";
		msg ~= got.to!istring();
		msg ~= "` token, expected ";

		const idxFinal = -1 + expected.length;
		foreach (idx, expectedType; expected) {
			if (idx > 1) {
				msg ~= (idx == idxFinal) ? " or " : ", ";
			}

			msg ~= "`";
			msg ~= expectedType.to!istring();
			msg ~= "`";
		}

		msg ~= ".";

		super(msg[], location, file, line, next);
	}
}

class AssemblerBadArgumentCountException : AssemblerException {
	ptrdiff_t got;
	ptrdiff_t expectedMin;
	ptrdiff_t expectedMax;
	string instructionID;

	this(
		ptrdiff_t got,
		ptrdiff_t expectedMin,
		ptrdiff_t expectedMax,
		string instructionID,
		Location location,
		istring file = __FILE__, size_t line = __LINE__, Throwable next = null,
	) @safe {
		this.got = got;
		this.expectedMin = expectedMin;
		this.expectedMax = expectedMax;
		this.instructionID = instructionID;

		istring msg;

		if (expectedMin == expectedMax) {
			msg = "Bad argument count for instruction `" ~ instructionID.idup ~ "`;"
				~ " expected `" ~ expectedMin.to!istring() ~ "`,"
				~ " got `" ~ got.to!istring() ~ "`.";
		}
		else {
			msg = "Bad argument count for instruction `" ~ instructionID.idup ~ "`;"
				~ " expected `" ~ expectedMin.to!istring() ~ "` .. `" ~ expectedMax.to!istring() ~ "`,"
				~ " got `" ~ got.to!istring() ~ "`.";
		}

		super(msg, location, file, line, next);
	}
}

struct AssemblyInstructionArgumentsParser {

	// dfmt off
	private enum State {
		initial     = 0b_000,
		instruction = 0b_011,
		parameter   = 0b_100,
		comma       = 0b_001,
	}
	// dfmt on

	private {
		AssemblyStatementLexer _lexer;

		State _state = State.initial;
		ptrdiff_t _argumentCount = -1;
		AssemblyToken _instruction;

		ptrdiff_t _argumentCountMin = -1;
		ptrdiff_t _argumentCountMax = -1;
	}

@safe:

	this(AssemblyStatementLexer lexer) {
		_lexer = lexer;
		this.skip();
	}

	this(AssemblyLexer lexer) {
		this(AssemblyStatementLexer(lexer));
	}

	void setupConstraints(ptrdiff_t argumentCountMin, ptrdiff_t argumentCountMax) {
		_argumentCountMin = argumentCountMin;
		_argumentCountMax = argumentCountMax;
		this.validateConstraints();
	}

	private void validateConstraints() {
		auto makeException(istring file = __FILE__, size_t line = __LINE__) {
			ptrdiff_t countFurther = 0;
			if (!this.empty) {
				auto clone = this;
				foreach (tmp; clone) {
					++countFurther;
				}

			}
			const got = _argumentCount + countFurther;

			return new AssemblerBadArgumentCountException(
				got,
				_argumentCountMin,
				_argumentCountMax,
				_instruction.data,
				_instruction.location,
				file,
				line,
			);
		}

		if (_argumentCountMin < 0) {
			return;
		}

		if (_argumentCount < _argumentCountMin) {
			if (this.empty) {
				throw makeException();
			}
		}

		if (_argumentCount > _argumentCountMax) {
			throw makeException();
		}
	}

	AssemblyLexer wrappedLexer() inout => _lexer.wrappedLexer;

	bool empty() const => _lexer.empty;

	AssemblyToken front() const => _lexer.front;

	void popFront() {
		_lexer.popFront();
		this.skip();
		this.validateConstraints();
	}

	private void skip() {
		if (_lexer.empty) {
			if (_state == State.comma) {
				throw new AssemblerException("Trailing comma.", _instruction.location);
			}
			return;
		}

		if (_state == State.initial) {
			if (_lexer.front.type != AssemblyToken.Type.identifier) {
				const errorMsg = "Identifier expected, got `" ~ _lexer.front.type.to!istring() ~ "`.";
				throw new AssemblerException(errorMsg, _lexer.front.location);
			}

			_state = State.instruction;
			_argumentCount = 0;
			_instruction = _lexer.front;

			return this.popFront();
		}

		if ((_state & State.comma) > 0) {
			switch (_lexer.front.type) {
			case AssemblyToken.Type.identifier:
			case AssemblyToken.Type.literalBoolean:
			case AssemblyToken.Type.literalCharacter:
			case AssemblyToken.Type.literalFloatingPoint:
			case AssemblyToken.Type.literalInteger:
			case AssemblyToken.Type.literalString:
				_state = State.parameter;
				++_argumentCount;
				return;

			default:
				const errorMsg = "Identifier or literal expected, got `" ~ _lexer.front.type.to!istring() ~ "`.";
				throw new AssemblerException(errorMsg, _lexer.front.location);
			}
		}

		if (_state == State.parameter) {
			if (_lexer.front.type != AssemblyToken.Type.comma) {
				const errorMsg = "Comma expected, got `" ~ _lexer.front.type.to!istring() ~ "`.";
				throw new AssemblerException(errorMsg, _lexer.front.location);
			}

			_state = State.comma;
			return this.popFront();
		}

		throw new AssemblerException("Unexpected parser state.", _lexer.front.location);
	}

	void throwIfUnexpectedTokenType(AssemblyToken.Type expected) {
		if (this.front.type == expected) {
			return;
		}

		const expectedTypes = [expected];
		throw new AssemblerUnexpectedTokenException(this.front.type, expectedTypes, this.front.location);
	}

	void throwIfUnexpectedTokenType(Types...)(Types expected) if (allSatisfy!((T) =>  is(T == AssemblyToken.Type))) {
		static foreach (expectedType; expected) {
			if (this.front.type == expectedType) {
				return;
			}
		}

		const expectedTypes = [expected];
		throw new AssemblerUnexpectedTokenException(this.front.type, expectedTypes, this.front.location);
	}
}

struct Assembler {
	import std.array : appender, Appender;

	private static struct Label {
		string identifier;
		size_t offset;
	}

	private static struct LabelPromise {
		size_t irIdx;
		string identifier;
		Location location;
	}

	private static struct State {
		Appender!(Instruction[]) ir;
		Label[string] labels;
		Appender!(LabelPromise[]) labelPromises;
		Appender!(string[]) registers;

	@safe:

		void addLabelForUpcomingInstruction(string identifier, const Location location) {
			const label = identifier in labels;

			if (label !is null) {
				const msg = "Duplicate label `" ~ identifier.idup ~ "`.";
				throw new AssemblerException(msg, location);
			}

			labels[identifier] = Label(identifier, ir.length);
		}

		RegisterID addOrResolveRegister(string identifier) @safe {
			foreach (RegisterID idx, string knownRegister; registers[]) {
				if (knownRegister == identifier) {
					return idx;
				}
			}

			registers ~= identifier;
			return -1 + registers.length;
		}

		void requestLabelForUpcomingInstruction(string identifier, const Location location) {
			labelPromises ~= LabelPromise(ir.length, identifier, location);
		}

		const(Label) resolveLabel(string identifier, const Location location) {
			const label = identifier in labels;

			if (label is null) {
				const msg = "Cannot resolve label `" ~ identifier.idup ~ "`: Not found.";
				throw new AssemblerException(msg, location);
			}

			return *label;
		}

		void resolveLabelPromises() {
			foreach (LabelPromise labelPromise; labelPromises) {
				const label = this.resolveLabel(labelPromise.identifier, labelPromise.location);
				ir[][labelPromise.irIdx].match!((ref instruction) {
					static if (__traits(hasMember, instruction, "targetLocation")) {
						instruction.targetLocation = label.offset;
					}
					else {
						enum msg = "Unsupported instruction type `" ~ typeof(instruction).stringof ~ "` for label promise.";
						assert(false, msg);
					}
				});
			}
		}
	}

	private {
		alias Lexer = AssemblyLexer;
		alias Token = AssemblyToken;

		State _state;
	}

@safe:

	Program assemble(string sourceCode, string sourceFile) {
		auto lexer = Lexer(sourceCode, sourceFile);
		return assemble(lexer);
	}

	Program assemble(AssemblyLexer lexer) {
		_state.ir = appender!(Instruction[])();
		_state.labels = null;
		_state.labelPromises = appender!(LabelPromise[]);
		_state.registers = appender!(string[])();

		// shebang handling
		if (!lexer.empty) {
			if (lexer.front.type == Token.Type.shebang) {
				lexer.popFront();
			}
		}

		while (!lexer.empty) {
			parseStatement(lexer);
		}

		_state.resolveLabelPromises();

		return Program(_state.ir[], _state.registers.length);
	}

	private void parseInstruction(ref Lexer lexer) {
		import std.string : toLower;

		const instructionName = lexer.front.data.toLower();

		// dfmt off
		parseInstructionSwitch: switch (instructionName) {
			static foreach (instruction; ISA.InstructionsSeq!()) {
				case idOf!instruction:
					auto instrArgsParser = AssemblyInstructionArgumentsParser(lexer);
					instruction.parse(instrArgsParser, _state);

					if (!instrArgsParser.empty) {
						assert(
							false,
							"Instruction `" ~ idOf!instruction ~ "`: "
							~ "`parse()` did not consume all tokens provided by argument parser."
						);
					}

					lexer = instrArgsParser.wrappedLexer;
					break parseInstructionSwitch;
			}

			default:
				throw new AssemblerException("Unknown instruction: " ~ instructionName.idup, lexer.front.location);
		}
		// dfmt on
	}

	private void parseLabel(ref Lexer lexer) {
		const token = lexer.front;
		lexer.popFront();
		lexer.popWhitespace();

		if (lexer.empty || (lexer.front.type != Token.Type.colon)) {
			assert(false, "Invalid label");
		}
		lexer.popFront();

		const identifier = token.data;
		_state.addLabelForUpcomingInstruction(identifier, token.location);
	}

	private void parseIdentifierConstruct(ref Lexer lexer) {
		auto lexerCopy = lexer;
		lexerCopy.popFront();
		lexerCopy.popWhitespace();

		if (!lexerCopy.empty) {
			if (lexerCopy.front.type == AssemblyToken.Type.colon) {
				this.parseLabel(lexer);
				return;
			}
		}

		this.parseInstruction(lexer);
	}

	private void parseStatement(ref Lexer lexer) {
		switch (lexer.front.type) {
		case Token.Type.error:
			throw new AssemblerException("Cannot parse erroneous token.", lexer.front.location);

		case Token.Type.comment:
		case Token.Type.eof:
		case Token.Type.linebreak:
		case Token.Type.whitespace:
			lexer.popFront();
			break;

		case Token.Type.identifier:
			this.parseIdentifierConstruct(lexer);
			break;

		default:
			throw new AssemblerException(
				"Unexpected token `" ~ lexer.front.data.idup ~ "`;"
					~ "`" ~ lexer.front.type.to!istring() ~ "` has no association with a statement.",
				lexer.front.location
			);
		}
	}
}

// === Virtual Machine =========================================================

struct ExitCode {
	import core.stdc.stdlib;
	import std.uni;

	private {
		int _value = EXIT_SUCCESS;
	}

@safe pure nothrow @nogc:

	public this(bool success) {
		if (success) {
			this.setSuccess();
		}
		else {
			this.setFailure();
		}
	}

	public this(int value) {
		_value = value;
	}

	T opCast(T : int)() const {
		return _value;
	}

	bool isSuccess() const => (_value == EXIT_SUCCESS);
	bool isFailure() const => !isSuccess;

	int get() const => _value;

	void set(int value) {
		_value = value;
	}

	ref inout(int) value() return inout => _value;

	void setSuccess() {
		_value = EXIT_SUCCESS;
	}

	void setFailure() {
		_value = EXIT_FAILURE;
	}
}

class VirtualMachineException : MindyscriptException {
	this(istring message, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		super(message, file, line, next);
	}
}

final class DuplicateProgramException : VirtualMachineException {
	string programIdentifier;

	this(string programIdentifier, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		this.programIdentifier = programIdentifier;
		super("Duplicate program identifier.", file, line, next);
	}
}

final class UndefinedProgramException : VirtualMachineException {
	string programIdentifier;

	this(string programIdentifier, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		this.programIdentifier = programIdentifier;
		super("Undefined program.", file, line, next);
	}
}

final class StackOverflowException : VirtualMachineException {
	this(istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		super("Stack overflow.", file, line, next);
	}
}

final class InvalidSettingException : VirtualMachineException {
	istring setting;
	istring issue;

	this(istring setting, istring issue, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		this.setting = setting;
		this.issue = issue;
		const msg = "`" ~ setting ~ "` " ~ issue;
		super(msg, file, line, next);
	}
}

final class VoidResultException : VirtualMachineException {
	this(istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		super("The result of the evaluated expression is `void`.", file, line, next);
	}
}

struct StackSettings {
	size_t sizeDefault = 4096;
	size_t sizeIncrements = 2048;
	size_t sizeMax = 8192;

	void validateThrow() @safe {
		if (sizeDefault <= 0) {
			throw new InvalidSettingException("stack.sizeDefault", "must be greater than zero.");
		}

		if (sizeIncrements <= 0) {
			throw new InvalidSettingException("stack.sizeIncrements", "must be greater than zero.");
		}

		if (sizeMax < sizeDefault) {
			throw new InvalidSettingException("stack.sizeMax", "must be greater than or equal to `stack.sizeDefault`.");
		}
	}
}

struct VirtualMachineSettings {
	StackSettings stack;

	void validateThrow() @safe {
		stack.validateThrow();
	}
}

private class Stack {

	static struct Frame {
		private {
			Stack _stack;
			size_t _offset;
			size_t _upper;
		}

		Variable[] data() @safe {
			return _stack._data[_offset .. _upper];
		}
	}

	private {
		StackSettings _settings;

		Variable[] _data = null;
		size_t _pointer = 0;
	}

@safe:

	public this(StackSettings settings) {
		_settings = settings;
	}

	private void grow() {
		if (_data is null) {
			_data = new Variable[](_settings.sizeDefault);
			return;
		}

		if (_data.length >= _settings.sizeMax) {
			throw new StackOverflowException();
		}

		_data.length += _settings.sizeIncrements;
	}

	private void growIfNecessary(size_t requested) {
		assert(_pointer <= _data.length);

		const free = _data.length - _pointer;

		if (free < requested) {
			this.grow();
		}
	}

	Frame push(size_t size) {
		this.growIfNecessary(size);

		const upper = _pointer + size;
		auto frame = Frame(this, _pointer, upper);

		_pointer = upper;
		return frame;
	}

	void pop(Frame frame) {
		assert(frame._stack is this);
		assert(frame._upper == _pointer);
		assert(frame._offset <= _pointer);

		_pointer = frame._offset;
	}
}

enum MemorySafety : bool {
	system = false,
	safe = true,
}

final class VirtualMachine(MemorySafety memorySafety = MemorySafety.system) {

	private {
		VirtualMachineSettings _settings;

		bool _machineInitialized = false;

		Program[string] _registry;
		Variable[string] _globals;
		Stack _stack;
	}

	public this(VirtualMachineSettings settings) @safe {
		_settings = settings;
	}

	void register(string identifier, Program program) {
		if ((identifier in _registry) !is null) {
			throw new DuplicateProgramException(identifier);
		}

		_registry[identifier] = program;
	}

	private void initializeMachineForced() @safe {
		if (_machineInitialized) {
			assert(false, "VM has already been initialized.");
		}

		_settings.validateThrow();

		_stack = new Stack(_settings.stack);
	}

	private void initializeMachine() {
		if (_machineInitialized) {
			return;
		}

		return initializeMachineForced();
	}

	ExitCode boot(const Program main) {
		ReturnValue result = this.execute(main);
		// dfmt off
		return result.match!(
			(Variable var) => var.match!(
				(bool exitSuccess) => ExitCode(exitSuccess),
				(int exitCodeValue) => ExitCode(exitCodeValue),
				_ => throw new VirtualMachineException("Bad exit-code type."),
			),
			(VMVoid _) => ExitCode(true),
		);
		// dfmt on
	}

	ReturnValue execute(string programIdentifier) {
		Program program;
		const loaded = this.load(programIdentifier, program);
		if (!loaded) {
			throw new UndefinedProgramException(programIdentifier);
		}

		return this.execute(program);
	}

	private bool load(string identifier, out Program program) {
		auto found = identifier in _registry;
		if (found is null) {
			return false;
		}

		program = *found;
		return true;
	}

	ReturnValue execute(const Program program) {
		this.initializeMachine();

		Stack.Frame stackFrame = _stack.push(program.registerCount);
		scope (exit) {
			_stack.pop(stackFrame);
		}

		ReturnValue returnValue = ReturnValue(VMVoid());

		void fetchDecodeAndExecute(ref size_t programCounter) {
			const fetchedInstruction = program.ir[programCounter];

			// dfmt off
			alias decodeAndExecute = std.sumtype.match!(
				(ISA.NoOpInstruction nop) {
					nop.execute();
				},
				(ISA.ReturnInstruction ret) {
					returnValue = ret.execute(stackFrame.data);
					programCounter = program.ir.length; // break program execution loop
				},
				(decodedInstruction) {
					import std.traits : hasUDA;

					alias InstructionType = typeof(decodedInstruction);
					enum  isJumpInstruction = hasUDA!(InstructionType, ISA.Jump);

					static if (isJumpInstruction) {
						enum usesRegisters = (
							__traits(hasMember, InstructionType, "subject") ||
							__traits(hasMember, InstructionType, "lhs")
						);

						static if (usesRegisters) {
							if (decodedInstruction.execute(stackFrame.data, programCounter)) {
								--programCounter; // compensate scheduled increment
							}
						}
						else {
							decodedInstruction.execute(programCounter);
							--programCounter; // compensate scheduled increment
						}
					}
					else {
						decodedInstruction.execute(stackFrame.data);
					}
				},
			);
			// dfmt on

			decodeAndExecute(fetchedInstruction);
		}

		for (size_t programCounter = 0; programCounter < program.ir.length; ++programCounter) {
			fetchDecodeAndExecute(programCounter);
		}

		return returnValue;
	}
}

// === Convenience functions ===================================================

Program assemble(string sourceCode, string sourceFile = null) @safe {
	auto assembler = Assembler();
	return assembler.assemble(sourceCode, sourceFile);
}

ReturnValue execute(MemorySafety memorySafety = MemorySafety.system)(const Program program, VirtualMachineSettings settings = VirtualMachineSettings()) {
	auto vm = new VirtualMachine!memorySafety(settings);
	return vm.execute(program);
}

Variable evaluate(MemorySafety memorySafety = MemorySafety.system)(const Program program, VirtualMachineSettings settings = VirtualMachineSettings()) {
	auto returnValue = execute!memorySafety(program, settings);
	return returnValue.match!(
		(Variable var) => var,
		(VMVoid void_) => throw new VoidResultException(),
	);
}

ExitCode boot(MemorySafety memorySafety = MemorySafety.system)(const Program program, VirtualMachineSettings settings = VirtualMachineSettings()) {
	auto vm = new VirtualMachine!memorySafety(settings);
	return vm.boot(program);
}

version (unittest) {
	private alias executeSafe = execute!(MemorySafety.safe);
	private alias evaluateSafe = evaluate!(MemorySafety.safe);
	private alias bootSafe = boot!(MemorySafety.safe);
}

@safe unittest {
	import std.traits : isSafe;

	alias executeSafe = execute!(MemorySafety.safe);
	static assert(isSafe!(executeSafe));

	alias evaluateSafe = evaluate!(MemorySafety.safe);
	static assert(isSafe!(evaluateSafe));

	alias bootSafe = boot!(MemorySafety.safe);
	static assert(isSafe!(bootSafe));
}

// === Emulator CLI App ========================================================

template EmulatorApp() {

	private enum Mode {
		none = 0,
		autoDetect,
		assembly,
		dlang,
		help,
	}

	final class DriverException : MindyscriptException {
		this(istring message, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
			super(message, file, line, next);
		}
	}

	///
	struct Driver {

		private {
			istring _arg0;
			Mode _mode = Mode.none;
			istring[] _sourceFiles;
		}

		///
		ExitCode run(istring[] args) {
			try {
				this.handleArgs(args);
				return executeMode();
			}
			catch (DriverException ex) {
				this.printException(ex);
				return ExitCode(false);
			}
			catch (MindyscriptException ex) {
				this.printException(ex);
				return ExitCode(false);
			}

			assert(false, "unreachable");
		}

		private ExitCode executeCode() {
			if (_sourceFiles.length == 0) {
				throw new DriverException("No source files provided.");
			}

			if (_sourceFiles.length == 1) {
				const sourceFile = _sourceFiles[0];
				const sourceCode = readSourceFile(sourceFile);
				return executeCodeAny(sourceCode, sourceFile);
			}

			auto exitCodeAll = ExitCode(true);
			foreach (sourceFile; _sourceFiles) {
				const sourceCode = readSourceFile(sourceFile);
				const exitCodeCur = executeCodeAny(sourceCode, sourceFile);
				if (!exitCodeCur.isSuccess) {
					exitCodeAll.setFailure();
				}
			}
			return exitCodeAll;
		}

		private ExitCode executeCodeAny(string sourceCode, istring sourceFile) {
			switch (_mode) {
			case Mode.assembly:
				return executeCodeAssembly(sourceCode, sourceFile);
			case Mode.autoDetect:
				return executeCodeAutoDetect(sourceCode, sourceFile);
			case Mode.dlang:
				return executeCodeDlang(sourceCode, sourceFile);
			default:
				assert(false, "Bad `_mode`.");
			}

			assert(false, "unreachable");
		}

		private ExitCode executeCodeAssembly(string sourceCode, istring sourceFile) {
			auto program = assemble(sourceCode, sourceFile);
			return execute(program);
		}

		private ExitCode executeCodeAutoDetect(string sourceCode, istring sourceFile) {
			import std.path : extension;
			import std.string : toLower;

			const fileExt = sourceFile.extension.toLower();

			switch (fileExt) {
			case ".d":
				return executeCodeDlang(sourceCode, sourceFile);

			case ".asm":
			case ".s":
				return executeCodeAssembly(sourceCode, sourceFile);

			default:
				throw new DriverException("Could not auto-detect type of file: " ~ sourceFile);
			}

			assert(false, "unreachable");
		}

		private ExitCode executeCodeDlang(string sourceCode, istring sourceFile) {
			// TODO: implement
			assert(false, "TODO");
		}

		private ExitCode executeMode() {
			final switch (_mode) {
			case Mode.none:
				if (_sourceFiles.length > 0) {
					_mode = Mode.autoDetect;
					goto case Mode.autoDetect;
				}
				throw new DriverException("Nothing to do.");

			case Mode.assembly:
			case Mode.autoDetect:
			case Mode.dlang:
				return executeCode();

			case Mode.help:
				printHelp();
				return ExitCode(true);
				break;
			}
		}

	@safe:

		private void handleArgs(istring[] args) {
			import std.file;
			import std.path;
			import std.string;

			if (args.length <= 1) {
				throw new DriverException("No arguments provided.");
			}

			_arg0 = args[0];

			foreach (arg; args[1 .. $]) {
				handleArg(arg);
			}
		}

		private void handleArg(istring arg) {
			import std.string : startsWith;

			if (arg.startsWith("--")) {
				handleDoubleDashArg(arg);
				return;
			}

			handleFilePathArg(arg);
		}

		private void handleDoubleDashArg(istring arg) {
			const argTrimmed = arg[2 .. $];

			switch (argTrimmed) {

			case "asm":
				setMode(Mode.assembly);
				break;

			case "dlang":
				setMode(Mode.dlang);
				break;

			case "help":
				_mode = Mode.help;
				break;

			default:
				throw new DriverException("Unsupported argument provided: " ~ arg);
			}
		}

		private void handleFilePathArg(istring arg) {
			import std.file : exists;

			if (!arg.exists()) {
				throw new DriverException("The specified path does not exist: " ~ arg);
			}

			_sourceFiles ~= arg;
		}

		private void printException(Exception ex) @system {
			static void printExceptionImpl(Exception ex, bool first) {
				import std.stdio : stderr;

				// dfmt off
				const prelude = (first)
					? "Error: "
					: "       ";
				// dfmt on

				debug {
					stderr.write(ex.file, "(", ex.line, "): ");
				}

				stderr.writeln(prelude, ex.message);

				if (auto locEx = cast(LocationException) ex) {
					stderr.writeln(locEx.location);
				}

				debug {
					try {
						stderr.write("----\n");
						foreach (t; ex.info) {
							stderr.writeln(t);
						}
					}
					catch (Throwable) {
						// ignore more errors
					}
				}
			}

			bool first = true;
			foreach (e; ex) {
				printExceptionImpl(ex, first);
				first = false;
			}
		}

		private void printHelp() @system {
			import std.stdio : stdout;

			stdout.writeln(
				"arsd.mindyscript :: Emulator CLI\n",
				"--------------------------------\n",
				"\n",
				"Usage:\n",
				"\t", _arg0, "  [<options>] <source files...>\n",
				"\n",
				"Available options:\n",
				"--asm          Assume input is VM assembly code.\n",
				"--dlang        Assume input is D source code.\n",
				"--help         Displays this help text.\n",
			);
		}

		private string readSourceFile(istring path) {
			import std.file : read;

			try {
				return cast(string) read(path);
			}
			catch (Exception ex) {
				throw new DriverException("Failed to read source file: " ~ path, __FILE__, __LINE__, ex);
			}
		}

		private void setMode(Mode mode)
		in (mode != Mode.none) {
			if (_mode != Mode.none) {
				throw new DriverException("Mode has already been set.");
			}

			_mode = mode;
		}
	}
}

mixin template EmulatorAppMain() {
	private int main(istring[] args) {
		import arsd.mindyscript;

		return cast(int) EmulatorApp!().Driver().run(args);
	}
}

version (MindyscriptEmulatorAppMain) {
	mixin EmulatorAppMain!();
}

// === Test Suite ==============================================================

// ==== Assembler Tests ========================================================

// empty file
@safe unittest {
	assert(assemble("").bootSafe().isSuccess);
	assert(assemble("\n").bootSafe().isSuccess);
	assert(assemble("\r\n").bootSafe().isSuccess);
}

// shebang
@safe unittest {
	assert(assemble("#!/usr/bin/env -S mindyscript --asm").bootSafe().isSuccess);
	assert(assemble("#!/usr/bin/env -S mindyscript --asm\n").bootSafe().isSuccess);
	assert(assemble("#!/usr/bin/env -S mindyscript --asm\r\n").bootSafe().isSuccess);
	assert(assemble("#!/usr/bin/env -S mindyscript --asm\nRET\n").bootSafe().isSuccess);
}

// no-op
@safe unittest {
	assert(assemble("NOP\nNOP\nNOP\nNOP\n").bootSafe().isSuccess);
}

// void return
@safe unittest {
	assert(assemble("RET\r\n").bootSafe().isSuccess);
	assert(assemble("RET\n").bootSafe().isSuccess);
	assert(assemble("RET").bootSafe().isSuccess);

	// case-insensitive
	assert(assemble("ret\n").bootSafe().isSuccess);
}

// int return
@safe unittest {
	assert(assemble("LDI a, 0\nRET a").bootSafe().isSuccess);
	assert(assemble("LDI a,0\nRET a").bootSafe().isSuccess);
	assert(assemble("LDI b, 1\nRET b").bootSafe().isFailure);
	assert(assemble("LDI b,1\nRET b").bootSafe().isFailure);
}

// move
@safe unittest {
	assert(assemble("LDI a,10\nLDI b,20\nMOV b,a\nRET b").evaluateSafe().get!int == 10);
	assert(assemble("LDI a,10\nMOV a,a\nRET a").evaluateSafe().get!int == 10);
	assert(assemble("LDI a,10\nLDI b,20\nMOV b,a\nMOV b,b\nRET b").evaluateSafe().get!int == 10);
}

// integer arithmetic
@safe unittest {
	// add integers
	assert(assemble("LDI a,4\nLDI b,3\nADD c,a,b\nRET c").evaluateSafe().get!int == 7);
	assert(assemble("LDI a,4\nLDI b,3\nADD a,a,b\nRET a").evaluateSafe().get!int == 7);
	assert(assemble("LDI a,4\nLDI b,3\nADD a,a,b\nADD a,a,b\nRET a").evaluateSafe().get!int == 10);

	// subtract integers
	assert(assemble("LDI a,7\nLDI b,4\nSUB c,a,b\nRET c").evaluateSafe().get!int == 3);
	assert(assemble("LDI a,7\nLDI b,4\nSUB a,a,b\nRET a").evaluateSafe().get!int == 3);

	// multiply integers
	assert(assemble("LDI a,7\nLDI b,4\nMUL c,a,b\nRET c").evaluateSafe().get!int == 28);
	assert(assemble("LDI a,7\nLDI b,4\nMUL a,a,b\nRET a").evaluateSafe().get!int == 28);

	// divide integers
	assert(assemble("LDI a,30\nLDI b,6\nDIV c,a,b\nRET c").evaluateSafe().get!int == 5);
	assert(assemble("LDI a,30\nLDI b,6\nDIV a,a,b\nRET a").evaluateSafe().get!int == 5);

	// reduce integers modulo
	assert(assemble("LDI a,32\nLDI b,10\nMOD c,a,b\nRET c").evaluateSafe().get!int == 2);
	assert(assemble("LDI a,32\nLDI b,10\nMOD a,a,b\nRET a").evaluateSafe().get!int == 2);
}

// floating-point arithmetic
@safe unittest {
	assert(assemble("LDI a,4.1\nLDI b,3.0\nADD c,a,b\nRET c").evaluateSafe().get!float.round() == 7);
	assert(assemble("LDI a,4.1\nLDI b,3.0\nADD a,a,b\nRET a").evaluateSafe().get!float.round() == 7);
	assert(assemble("LDI a,4  \nLDI b,3.0\nADD c,a,b\nRET c").evaluateSafe().get!float.round() == 7);
	assert(assemble("LDI a,4.0\nLDI b,3  \nADD c,a,b\nRET c").evaluateSafe().get!float.round() == 7);

	assert(assemble("LDI a,4.9\nLDI b,3.1\nSUB c,a,b\nRET c").evaluateSafe().get!float.round() == 2);

	assert((assemble("LDI a,5.0\nLDI b,2.5\nMUL c,a,b\nRET c").evaluateSafe().get!float * 10).round() == 125);
	assert((assemble("LDI a,7.0\nLDI b,2.0\nDIV c,a,b\nRET c").evaluateSafe().get!float * 10).round() == 35);
	assert(assemble("LDI a,8.0\nLDI b,3.0\nMOD c,a,b\nRET c").evaluateSafe().get!float.round() == 2);
}

// jumps
@safe unittest {
	// JAL
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nJAL target\nRET a\ntarget:RET b\nRET c").evaluateSafe().get!int == 2);
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nJAL target\nRET a\ntarget: RET b\nRET c").evaluateSafe().get!int == 2);
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nJAL target\nRET a\ntarget:\nRET b\nRET c").evaluateSafe().get!int == 2);
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nJAL 5\nRET a\nRET b\nRET c").evaluateSafe().get!int == 2);

	// JNZ
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nLDI s,9\nJNZ t,s\nRET a\nt: RET b\nRET c").evaluateSafe().get!int == 2);
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nLDI s,0\nJNZ t,s\nRET a\nt: RET b\nRET c").evaluateSafe().get!int == 1);

	// JZ
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nLDI s,9\nJZ t,s\nRET a\nt: RET b\nRET c").evaluateSafe().get!int == 1);
	assert(assemble("LDI a,1\nLDI b,2\nLDI c,3\nLDI s,0\nJZ t,s\nRET a\nt: RET b\nRET c").evaluateSafe().get!int == 2);
}
