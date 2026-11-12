class_name Dictation
extends Node
## Hold-to-talk recording: the microphone on a silent bus with a capture effect. The recording is given in pieces, cut
## at each pause, as 16 kHz mono 16-bit WAV for the engine's transcription: the text can follow the voice, phrase by
## phrase, and a long dictation is never one long recording. Nothing is recorded while the key is not held.

signal level(value: float)
signal piece(index: int, wav: PackedByteArray, seconds: float)

const SPEECH := 0.03     # louder than this, someone speaks
const QUIET := 0.02      # quieter than this for PAUSE seconds, after speech: a pause, where a piece ends
const PAUSE := 0.9      # 0.7 cut the owner's sentences at each hesitation (2026-11-11)
const MIN_PIECE := 1.2   # seconds: a piece is never shorter (a breath is not a pause)
const MAX_PIECE := 30.0  # seconds: a piece is never longer, pause or not

var bus := -1
var capture: AudioEffectCapture
var player: AudioStreamPlayer
var recording := false
var frames := PackedVector2Array()  # the piece being recorded
var started_ms := 0
var pieces := 0          # pieces given so far in this recording
var _heard := false      # speech in the piece being recorded
var _ever := false       # speech anywhere in this recording; when never, the levels tell nothing and everything is given
var _quiet := 0.0        # seconds of quiet at the end of the piece being recorded


func _ready() -> void:
	bus = AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Dictation")
	capture = AudioEffectCapture.new()
	capture.buffer_length = 5.0  # it is emptied at every frame; with 0.5 s, a half-second stall of the app lost words
	AudioServer.add_bus_effect(bus, capture)
	AudioServer.set_bus_volume_db(bus, -80.0)  # captured, never played back
	player = AudioStreamPlayer.new()
	player.bus = "Dictation"
	add_child(player)


func available() -> bool:
	return AudioServer.get_input_device_list().size() > 0


func start() -> void:
	frames = PackedVector2Array()
	pieces = 0
	_heard = false
	_ever = false
	_quiet = 0.0
	capture.clear_buffer()
	if player.stream == null:
		player.stream = AudioStreamMicrophone.new()
	player.play()
	recording = true
	started_ms = Time.get_ticks_msec()


func _process(_d: float) -> void:
	if not recording:
		return
	var n := capture.get_frames_available()
	if n > 0:
		feed(capture.get_buffer(n))


## What the microphone gave since the last frame. A pause after speech ends the piece, which is given at once.
func feed(chunk: PackedVector2Array) -> void:
	frames.append_array(chunk)
	var peak := 0.0
	for i in range(0, chunk.size(), 32):
		peak = maxf(peak, absf(chunk[i].x))
	level.emit(peak)
	var rate := AudioServer.get_mix_rate()
	if peak > SPEECH:
		_heard = true
		_ever = true
		_quiet = 0.0
	elif peak < QUIET:
		_quiet += chunk.size() / rate
	var length := frames.size() / rate
	if (_heard and _quiet >= PAUSE and length >= MIN_PIECE) or length >= MAX_PIECE:
		_give()


func _give() -> void:
	var rate := AudioServer.get_mix_rate()
	var seconds := frames.size() / rate
	var wav := to_wav(frames, rate)
	frames = PackedVector2Array()
	_heard = false
	_quiet = 0.0
	pieces += 1
	piece.emit(pieces - 1, wav, seconds)


## The key is released: what is left is the last piece. Returns how many pieces this recording gave in all (0: a
## tap). A silent tail is not given, unless no speech was ever told apart (a very quiet microphone: all of it goes).
func stop() -> int:
	recording = false
	player.stop()
	var n := capture.get_frames_available()
	if n > 0:
		frames.append_array(capture.get_buffer(n))
	if frames.size() / AudioServer.get_mix_rate() >= 0.4 and (_heard or not _ever):
		_give()
	frames = PackedVector2Array()
	return pieces


## Stereo float frames at the mix rate -> WAV bytes, 16 kHz, mono, 16-bit (what transcription needs, small).
static func to_wav(src: PackedVector2Array, rate: float, out_rate := 16000) -> PackedByteArray:
	var step := rate / out_rate
	var count := int(src.size() / step)
	var pcm := PackedByteArray()
	pcm.resize(count * 2)
	for i in count:
		var f: Vector2 = src[mini(int(i * step), src.size() - 1)]
		var v := clampf((f.x + f.y) * 0.5, -1.0, 1.0)
		pcm.encode_s16(i * 2, int(v * 32767.0))
	var h := PackedByteArray()
	h.resize(44)
	h.encode_u32(0, 0x46464952)        # RIFF
	h.encode_u32(4, 36 + pcm.size())
	h.encode_u32(8, 0x45564157)        # WAVE
	h.encode_u32(12, 0x20746d66)       # fmt
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)
	h.encode_u16(22, 1)
	h.encode_u32(24, out_rate)
	h.encode_u32(28, out_rate * 2)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u32(36, 0x61746164)       # data
	h.encode_u32(40, pcm.size())
	h.append_array(pcm)
	return h
