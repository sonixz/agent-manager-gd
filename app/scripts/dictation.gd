class_name Dictation
extends Node
## Hold-to-talk recording: the microphone on a silent bus with a capture effect. The recording is given in pieces, cut
## at each pause, as 16 kHz mono 16-bit WAV for the engine's transcription: the text can follow the voice, phrase by
## phrase. The pieces are what is shown while speaking; the whole recording, to its very end, is what is written down
## when the key is released. Nothing is recorded while the key is not held, but for a moment after its release.

signal level(value: float)
signal piece(index: int, wav: PackedByteArray, seconds: float)
signal mute(seconds: float)  # the key is held and the microphone has given nothing for that long
signal ended(seconds: float)  # the listening is over: how much was recorded in all (0: a tap, nothing to write down)

const SPEECH := 0.03     # louder than this, someone speaks
const QUIET := 0.02      # quieter than this for PAUSE seconds, after speech: a pause, where a piece ends
# The pieces are only what is shown while speaking: the text that is kept comes from the whole recording, written
# once more in one piece. So they are cut early, for the words to follow the voice (the owner, 2026-11-11: « le texte
# apparaît pas vraiment en real time »): at half a second of quiet, and, once a piece is a few seconds long, at the
# first dip of the voice.
const PAUSE := 0.5
const MIN_PIECE := 1.2   # seconds: a piece is never shorter (a breath is not a pause)
const SOON := 4.0        # seconds: a piece this long ends at the first dip
const DIP := 0.25        # seconds of quiet that make a dip: a gap between phrases (0.15 s can be a consonant inside a word)
const MAX_PIECE := 12.0  # seconds: a piece is never longer, pause or not
# The key is released as the last word is said, often before its end, and the sound takes a moment to come through
# the audio device: it goes on listening this long. Without it the last syllables were cut (the owner, 2026-11-11:
# « il capte pas la fin de mes phrases »).
const TAIL := 0.4

var bus := -1
var capture: AudioEffectCapture
var player: AudioStreamPlayer
var recording := false
var closing := false     # the key is released: it listens a little longer (TAIL), then ends
var frames := PackedVector2Array()  # the piece being recorded
var started_ms := 0
var pieces := 0          # pieces given so far in this recording
var whole := PackedByteArray()  # every sample of the recording, as 16 kHz mono 16-bit: the pieces end to end, then its end
var rest := PackedByteArray()   # its end, which no piece held: what was said between the last cut and the key's release
var _heard := false      # speech in the piece being recorded
var _ever := false       # speech anywhere in this recording; when never, the levels tell nothing and everything is given
var _quiet := 0.0        # seconds of quiet at the end of the piece being recorded
var _live := false       # recording from the real microphone (the checks feed sound themselves)
var _fed_ms := 0         # when the audio last gave frames at all
var _loudest := 0.0      # the loudest sample of this recording: exactly 0 means no microphone behind the frames
var _reopened := false   # it was opened again once in this recording
var _told := false       # « it gives nothing » was said once in this recording
var _closing_ms := 0     # when the key was released
var _held := 0.0         # seconds recorded while the key was held


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
	whole = PackedByteArray()
	rest = PackedByteArray()
	pieces = 0
	closing = false
	_heard = false
	_ever = false
	_quiet = 0.0
	capture.clear_buffer()
	if player.stream == null:
		player.stream = AudioStreamMicrophone.new()
	player.play()
	recording = true
	started_ms = Time.get_ticks_msec()
	_live = true
	_loudest = 0.0
	_fed_ms = started_ms
	_reopened = false
	_told = false


func _process(_d: float) -> void:
	if not recording:
		return
	var n := capture.get_frames_available()
	if n > 0:
		_fed_ms = Time.get_ticks_msec()
		feed(capture.get_buffer(n))
	if closing and Time.get_ticks_msec() - _closing_ms >= TAIL * 1000.0:
		_end()
		return
	if _live:
		# An open microphone always gives something: frames at every tick, and never a perfect zero for long (a room
		# is never that quiet). No frame at all, or nothing but zeros since the key went down, means it is gone:
		# Windows took the audio device away (a headset switched off, another default device). It happened on
		# 2026-11-11: the box listened, nothing came, and nothing said why.
		var now := Time.get_ticks_msec()
		var dry := maxi(now - _fed_ms, (now - started_ms) if _loudest == 0.0 else 0)
		if dry > 1500 and not _reopened:
			_reopened = true
			reopen()
		elif dry > 3500 and not _told:
			_told = true
			mute.emit(dry / 1000.0)


## Opens the microphone again: after the audio device changed, the old opening gives nothing any more.
func reopen() -> void:
	player.stop()
	player.stream = AudioStreamMicrophone.new()
	player.play()


## What the microphone gave since the last frame. A pause after speech ends the piece, which is given at once.
func feed(chunk: PackedVector2Array) -> void:
	frames.append_array(chunk)
	var peak := 0.0
	for i in range(0, chunk.size(), 32):
		peak = maxf(peak, absf(chunk[i].x))
	level.emit(peak)
	_loudest = maxf(_loudest, peak)
	var rate := AudioServer.get_mix_rate()
	if peak > SPEECH:
		_heard = true
		_ever = true
		_quiet = 0.0
	elif peak < QUIET:
		_quiet += chunk.size() / rate
	if closing:
		return  # the key is released: what comes now is the end of the recording, not a new piece
	var length := frames.size() / rate
	if _heard and ((_quiet >= PAUSE and length >= MIN_PIECE) or (_quiet >= DIP and length >= SOON)):
		_give()
	elif length >= MAX_PIECE:
		_give()


func _give() -> void:
	var rate := AudioServer.get_mix_rate()
	var seconds := frames.size() / rate
	var wav := to_wav(frames, rate)
	whole.append_array(wav.slice(44))
	frames = PackedVector2Array()
	_heard = false
	_quiet = 0.0
	pieces += 1
	piece.emit(pieces - 1, wav, seconds)


## The key is released. It listens a little longer (TAIL), then `ended` tells how much was recorded.
func release() -> void:
	if not recording or closing:
		return
	closing = true
	_closing_ms = Time.get_ticks_msec()
	_held = whole.size() / 32000.0 + frames.size() / AudioServer.get_mix_rate()


## The key is pressed again before the listening ended: the same recording goes on.
func resume() -> void:
	closing = false


## The listening is over. What was said since the last cut joins the whole recording, always: it is short, or said
## lower than the rest, and it is the end of the sentence. Before, it was only kept when it was long and loud enough,
## and the last words were lost (the owner, 2026-11-11: « la plupart de mes derniers mots sont jamais pris »).
## Nothing is to be written down after a tap: the key barely held, and no speech.
func _end() -> void:
	recording = false
	closing = false
	_live = false
	player.stop()
	var n := capture.get_frames_available()
	if n > 0:
		frames.append_array(capture.get_buffer(n))
	rest = to_wav(frames, AudioServer.get_mix_rate()).slice(44)
	whole.append_array(rest)
	frames = PackedVector2Array()
	ended.emit(whole.size() / 32000.0 if (_ever or _held >= 0.4) else 0.0)


## The whole recording as one WAV: written down in one piece, it gives the text that is kept.
func whole_wav() -> PackedByteArray:
	return wav_of(whole)


## Its end alone, which no piece held: kept to be written down again when the whole could not be.
func rest_wav() -> PackedByteArray:
	return wav_of(rest)


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
	return wav_of(pcm, out_rate)


## 16-bit mono samples with the WAV header in front.
static func wav_of(pcm: PackedByteArray, out_rate := 16000) -> PackedByteArray:
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
