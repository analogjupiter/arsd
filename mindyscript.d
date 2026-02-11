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

	- dmd  -unittest -main -run mindyscript.d
	- ldc2 -unittest -main -run mindyscript.d
	- rdmd -unittest -main      mindyscript.d
 +/
module arsd.mindyscript;

import std.conv : to;
static import std.sumtype;
static import std.typecons;

// === Commons =================================================================

private {
	alias string = const(char)[];
	alias istring = object.string;
	alias match = std.sumtype.match;
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
	int,
	float,
);

struct VMVoid {
}

alias ReturnValue = std.sumtype.SumType!(Variable, VMVoid);

// === ISA =====================================================================

alias RegisterID = size_t;

alias Registers = Variable[];

/++
	Instruction Set Architecture
 +/
struct ISA {
	@disable this();

	private struct Op {
		istring id;
	}

	@Op("nop")
	struct NoOpInstruction {
		void execute() @safe {
			return; // Do nothing.
		}

		static void parse(ref AssemblyLexer lexer, ref Assembler.State state) @safe {
			lexer.popFront();
		}
	}

	@Op("ldi")
	struct LoadImmediateInstruction {
		RegisterID destination;
		Variable value;

		void execute(Registers rg) @safe {
			rg[destination] = value;
		}

		static void parse(ref AssemblyLexer lexer, ref Assembler.State state) @safe {
			lexer.popFront();
		}
	}

	@Op("ret")
	struct ReturnInstruction {
		RegisterID a;
		bool returnVoid;

		ReturnValue execute(Registers rg) @safe {
			if (returnVoid) {
				return ReturnValue(VMVoid());
			}

			return ReturnValue(rg[a]);
		}

		static void parse(ref AssemblyLexer lexer, ref Assembler.State state) @safe {
			lexer.popFront();
			lexer.popWhitespace();

			// RET void
			if (lexer.front.type == AssemblyToken.Type.linebreak) {
				state.ir ~= Instruction(ReturnInstruction(RegisterID.max, true));
				return;
			}

			if (lexer.front.type == AssemblyToken.Type.identifier) {
				const registerID = state.addOrResolveRegister(lexer.front.data);
				state.ir ~= Instruction(ReturnInstruction(registerID, false));
				return;
			}

			throw new AssemblerException("Unexpected token type.", lexer.front.location);
		}
	}

	@Op("add")
	struct AddInstruction {
		RegisterID a;
		RegisterID b;
		RegisterID sum;

		void execute(Registers rg) @safe {
			match!(
				(typeof(null) a, typeof(null) b) { rg[sum] = null; },
				(typeof(null) a, b) { rg[sum] = null; },
				(a, typeof(null) b) { rg[sum] = null; },
				(a, b) { rg[sum] = a + b; },
			)(rg[a], rg[b]);
		}

		static void parse(ref AssemblyLexer lexer, ref Assembler.State state) @safe {
			lexer.popFront();
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
		whitespace,
		linebreak,
		comment,
		label,
		identifier,

		literalBoolean,
		literalCharacter,
		literalInteger,
		literalFloatingPoint,
		literalString,
	}

	Type type;
	string data;
	Location location;
}

class AssemblyLexerException : MindyscriptException, LocationException {
	Location _location;

	mixin LocationProperty!_location;

	this(istring message, Location location, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		_location = location;
		super(message, file, line, next);
	}
}

struct AssemblyLexer {
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

	private size_t scanRawIdentifier() {
		import std.ascii : isAlphaNum, isWhite;

		foreach (size_t idx, char c; _source) {
			if (c.isAlphaNum || (c == '_')) {
				continue;
			}

			if (c.isWhite) {
				return idx;
			}

			throw new AssemblyLexerException(
				"Unexpected character in identifier.",
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
		import std.ascii : isDigit, isWhite;

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
		import std.ascii : isDigit;

		if ((_source[0] == '0') && (_source.length >= 2)) {
			if (_source[1] == 'x') {
			}

			if (_source[1] == 'b') {
			}
		}
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

		case ' ':
			this.lexWhitespace();
			break;

		case '0': .. case '9':
			this.lexNumericLiteral();
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

class AssemblerException : MindyscriptException {
	Location location;

	this(istring message, Location location, istring file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe {
		this.location = location;
		super(message, file, line, next);
	}
}

struct Assembler {
	import std.array : appender, Appender;

	private struct Label {
		string name;
		size_t offset;
	}

	private struct State {
		Appender!(Instruction[]) ir;
		Appender!(Label[]) labels;
		Appender!(string[]) registers;

		RegisterID addOrResolveRegister(string identifier) @safe {
			foreach (RegisterID idx, string knownRegister; registers[]) {
				if (knownRegister == identifier) {
					return idx;
				}
			}

			registers ~= identifier;
			return -1 + registers.length;
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
		_state.labels = appender!(Label[])();
		_state.registers = appender!(string[])();

		while (!lexer.empty) {
			parseStatement(lexer);
		}

		return Program(_state.ir[], _state.registers.length);
	}

	private void parseInstruction(ref Lexer lexer) {
		import std.string : toLower;

		const instructionName = lexer.front.data.toLower();

		// dfmt off
		parseInstructionSwitch: switch (instructionName) {
			static foreach (instruction; ISA.InstructionsSeq!()) {
				case idOf!instruction:
					instruction.parse(lexer, _state);
					break parseInstructionSwitch;
			}

			default:
				throw new AssemblerException("Unknown instruction: " ~ instructionName.idup, lexer.front.location);
		}
		// dfmt on
	}

	private void parseStatement(ref Lexer lexer) {
		switch (lexer.front.type) {
		case Token.Type.error:
			assert(false, "TODO");

		case Token.Type.comment:
		case Token.Type.eof:
		case Token.Type.linebreak:
		case Token.Type.whitespace:
			lexer.popFront();
			break;

		case Token.Type.identifier:
			parseInstruction(lexer);
			break;

		default:
			// TODO: something else
			lexer.popFront();
			break;
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

	int get() const => _value;

	void set(int value) {
		_value = value;
	}

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

	ExitCode boot(Program main) {
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

	ReturnValue execute(Program program) {
		this.initializeMachine();

		Stack.Frame stackFrame = _stack.push(program.registerCount);
		scope (exit) {
			_stack.pop(stackFrame);
		}

		ReturnValue returnValue = ReturnValue(VMVoid());

		for (size_t programCounter = 0; programCounter < program.ir.length; ++programCounter) {
			const fetchedInstruction = program.ir[programCounter];

			// dfmt off
			fetchedInstruction.match!(
				(ISA.AddInstruction add) { add.execute(stackFrame.data); },
				(ISA.LoadImmediateInstruction ldi) { ldi.execute(stackFrame.data); },
				(ISA.NoOpInstruction nop) { nop.execute(); },
				(ISA.ReturnInstruction ret) {
					returnValue = ret.execute(stackFrame.data);
					programCounter = program.ir.length; // break program execution loop
				},
			);
			// dfmt on
		}

		return returnValue;
	}
}

// === Convenience functions ===================================================

Program assemble(string sourceCode, string sourceFile = null) @safe {
	auto assembler = Assembler();
	return assembler.assemble(sourceCode, sourceFile);
}

ExitCode execute(MemorySafety memorySafety = MemorySafety.system)(Program program, VirtualMachineSettings settings = VirtualMachineSettings()) {
	auto vm = new VirtualMachine!memorySafety(settings);
	return vm.boot(program);
}

version (unittest) {
	private alias executeSafe = execute!(MemorySafety.safe);
}

@safe unittest {
	import std.traits : isSafe;

	alias executeSafe = execute!(MemorySafety.safe);
	static assert(isSafe!(executeSafe));
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
				return executeCodeAssembly(sourceCode);
			case Mode.autoDetect:
				return executeCodeAutoDetect(sourceCode, sourceFile);
			case Mode.dlang:
				return executeCodeDlang(sourceCode);
			default:
				assert(false, "Bad `_mode`.");
			}

			assert(false, "unreachable");
		}

		private ExitCode executeCodeAssembly(string sourceCode) {
			auto program = assemble(sourceCode);
			return execute(program);
		}

		private ExitCode executeCodeAutoDetect(string sourceCode, istring sourceFile) {
			import std.path : extension;
			import std.string : toLower;

			const fileExt = sourceFile.extension.toLower();

			switch (fileExt) {
			case ".d":
				return executeCodeDlang(sourceCode);

			case ".asm":
			case ".s":
				return executeCodeAssembly(sourceCode);

			default:
				throw new DriverException("Could not auto-detect type of file: " ~ sourceFile);
			}

			assert(false, "unreachable");
		}

		private ExitCode executeCodeDlang(string sourceCode) {
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

				stderr.writeln(prelude, ex.message);

				if (auto locEx = cast(LocationException) ex) {
					stderr.writeln(locEx.location);
				}

				if (ex.next !is null) {
					printExceptionImpl(ex, false);
				}
			}

			printExceptionImpl(ex, true);
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
	assert(assemble("").executeSafe().isSuccess);
	assert(assemble("\n").executeSafe().isSuccess);
	assert(assemble("\r\n").executeSafe().isSuccess);
}

// void return
@safe unittest {
	assert(assemble("RET\n").executeSafe().isSuccess);
	assert(assemble("RET").executeSafe().isSuccess);

	// case-insensitive
	assert(assemble("ret\n").executeSafe().isSuccess);
}

// int return
@safe unittest {
	assert(assemble("LDI a, 0\nRET a").executeSafe().isSuccess);
}
