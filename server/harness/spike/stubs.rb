# D7 STEP-0 GATE spike — RGSS/mkxp-z replacement stubs for headless MRI 3.1.
# Throwaway. Order matters: this file must load before any Essentials script.

PEMK_ROOT = "/mnt/c/Pokemon Essentials MMO Kit"

#===============================================================================
# Marshal-based data loading (mkxp-z load_data replacement)
#===============================================================================
def load_data(path)
  full = File.join(PEMK_ROOT, path)
  raise "load_data: missing #{full}" if !File.exist?(full)
  Marshal.load(File.binread(full))
end

def save_data(data, path); end

#===============================================================================
# Kernel helpers Essentials defines in 001_Technical
#===============================================================================
def validate(hash)
  hash.each do |value, types|
    types = [types] if !types.is_a?(Array)
    next if types.any? { |t| value.is_a?(t) }
    raise ArgumentError, "Invalid argument #{value.inspect}, expected #{types.inspect}"
  end
end

# v21.1 defines this as a Kernel function (called bare inside battle classes)
def nil_or_empty?(str)
  return str.nil? || !str.is_a?(String) || str.empty?
end

class Module
  def deprecated_method_alias(old_name, new_name, removal_in: nil)
    alias_method(old_name, new_name) if method_defined?(new_name) || private_method_defined?(new_name)
  end
end

def echo(msg); end
def echoln(msg); end

def pbPrintException(e)
  STDERR.puts "[EXC] #{e.class}: #{e.message}"
  STDERR.puts e.backtrace[0, 12].join("\n") if e.backtrace
end

#===============================================================================
# Translation layer — passthrough
#===============================================================================
def _INTL(msg, *params)
  s = msg.dup
  params.each_with_index { |p, i| s = s.gsub("{#{i + 1}}", p.to_s) }
  return s
end

def _ISPRINTF(msg, *params)
  s = msg.dup
  params.each_with_index do |p, i|
    s = s.gsub(/\{#{i + 1}:([^}]+)\}/) { sprintf("%#{$1}", p) }
  end
  return s
end

def _I(msg, *params); _INTL(msg, *params); end
def _MAPINTL(_mapid, msg, *params); _INTL(msg, *params); end

module MessageTypes
  def self.const_missing(_name); 0; end
end

def pbGetMessageFromHash(_type, key); key; end
def pbGetMessage(_type, _id); ""; end

#===============================================================================
# PBDebug — collect instead of writing Data/debuglog.txt
#===============================================================================
module PBDebug
  LOG = []
  def self.log(msg);          LOG.push(msg); end
  def self.log_message(msg);  LOG.push(msg); end
  def self.log_header(msg);   LOG.push(msg); end
  def self.log_ai(msg);       LOG.push("[AI] #{msg}"); end
  def self.log_score_change(*args); end
  def self.dump(msg); end
  def self.logonerr
    yield
  rescue StandardError => e
    pbPrintException(e)
  end
end

#===============================================================================
# RGSS shells (only reached if something non-visual touches them)
#===============================================================================
class Rect
  attr_accessor :x, :y, :width, :height
  def initialize(x = 0, y = 0, w = 0, h = 0); @x, @y, @width, @height = x, y, w, h; end
  def set(x, y, w, h); @x, @y, @width, @height = x, y, w, h; end
  def empty; @x = @y = @width = @height = 0; end
end

class Color
  attr_accessor :red, :green, :blue, :alpha
  def initialize(r = 0, g = 0, b = 0, a = 255); @red, @green, @blue, @alpha = r, g, b, a; end
  def self.new_from_rgb(param); Color.new(0, 0, 0); end
end

class Tone
  attr_accessor :red, :green, :blue, :gray
  def initialize(r = 0, g = 0, b = 0, gray = 0); @red, @green, @blue, @gray = r, g, b, gray; end
end

class Font
  attr_accessor :name, :size, :bold, :italic, :color, :outline, :shadow
  def initialize; @name = "Arial"; @size = 22; end
  def self.exist?(_name); true; end
  def self.default_name; "Arial"; end
end

class Bitmap
  attr_accessor :font
  attr_reader :width, :height
  def initialize(w = 32, h = 32); @width, @height = (w.is_a?(String) ? 32 : w), (w.is_a?(String) ? 32 : h); @font = Font.new; end
  def dispose; @disposed = true; end
  def disposed?; @disposed == true; end
  def rect; Rect.new(0, 0, @width, @height); end
  def blt(*args); end
  def stretch_blt(*args); end
  def fill_rect(*args); end
  def clear; end
  def get_pixel(_x, _y); Color.new(0, 0, 0, 0); end
  def set_pixel(*args); end
  def draw_text(*args); end
  def text_size(_str); Rect.new(0, 0, 32, 16); end
  def method_missing(_name, *args); nil; end
  def respond_to_missing?(*); true; end
end

class Viewport
  attr_accessor :rect, :visible, :z, :ox, :oy, :color, :tone
  def initialize(*args)
    @rect = args[0].is_a?(Rect) ? args[0] : Rect.new(*(args.empty? ? [0, 0, 640, 384] : args))
    @visible = true; @z = 0; @ox = 0; @oy = 0
    @color = Color.new(0, 0, 0, 0); @tone = Tone.new
  end
  def dispose; @disposed = true; end
  def disposed?; @disposed == true; end
  def update; end
  def flash(*args); end
end

class Sprite
  attr_accessor :bitmap, :src_rect, :visible, :x, :y, :z, :ox, :oy,
                :zoom_x, :zoom_y, :angle, :mirror, :bush_depth, :opacity,
                :blend_type, :color, :tone, :viewport
  def initialize(viewport = nil)
    @viewport = viewport; @src_rect = Rect.new; @visible = true
    @x = @y = @z = @ox = @oy = 0; @zoom_x = @zoom_y = 1.0
    @angle = 0; @mirror = false; @opacity = 255; @blend_type = 0
    @color = Color.new(0, 0, 0, 0); @tone = Tone.new
  end
  def dispose; @disposed = true; end
  def disposed?; @disposed == true; end
  def update; end
  def flash(*args); end
  def width; @bitmap ? @bitmap.width : 0; end
  def height; @bitmap ? @bitmap.height : 0; end
end

class Plane < Sprite; end

class Window
  def initialize(*args); end
  def method_missing(_name, *args); nil; end
  def respond_to_missing?(*); true; end
end

module RPG
  class Cache
    def self.method_missing(_name, *args); Bitmap.new(32, 32); end
    def self.respond_to_missing?(*); true; end
  end
end

#===============================================================================
# Graphics / Input / Audio / System
#===============================================================================
module Graphics
  @frame_count = 0
  class << self
    attr_accessor :frame_count
    def update; @frame_count += 1; end
    def frame_rate; 60; end
    def frame_reset; end
    def freeze; end
    def transition(*args); end
    def fadeout(*args); end
    def fadein(*args); end
    def width; 640; end
    def height; 384; end
    def delta; 1.0 / 60; end
    def delta_s; 1.0 / 60; end
    def average_frame_rate; 60; end
    def resize_screen(*args); end
    def snap_to_bitmap; Bitmap.new(width, height); end
  end
end

module Input
  UP = 8; DOWN = 2; LEFT = 4; RIGHT = 6
  USE = 5; BACK = 13; ACTION = 14; AUX1 = 15; AUX2 = 16
  SPECIAL = 17; JUMPUP = 18; JUMPDOWN = 19; JUMPLEFT = 20; JUMPRIGHT = 21
  def self.const_missing(_name); 0; end
  def self.update; end
  def self.trigger?(_key); false; end
  def self.triggerex?(_key); false; end
  def self.press?(_key); false; end
  def self.pressex?(_key); false; end
  def self.repeat?(_key); false; end
  def self.repeatex?(_key); false; end
  def self.release?(_key); false; end
  def self.dir4; 0; end
  def self.dir8; 0; end
  def self.time?(_key); 0; end
  def self.text_input; ""; end
end

module Audio
  def self.method_missing(_name, *args); nil; end
  def self.respond_to_missing?(*); true; end
end

module System
  def self.uptime; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
  def self.platform; "Windows"; end
  def self.game_title; "PEMK Headless Spike"; end
  def self.data_directory; "/tmp/pemk-spike/savedata"; end
  def self.show_settings; end
end

def pbSEPlay(*args); end
def pbSEStop(*args); end
def pbSEFade(*args); end
def pbBGMPlay(*args); end
def pbBGMStop(*args); end
def pbBGMFade(*args); end
def pbBGSPlay(*args); end
def pbBGSStop(*args); end
def pbMEPlay(*args); end
def pbMEStop(*args); end
def pbMEFade(*args); end
def pbPlayDecisionSE; end
def pbPlayCancelSE; end
def pbPlayBuzzerSE; end
def pbPlayCursorSE; end
def pbCryFrameLength(*args); 0; end
def pbResolveAudioSE(*args); nil; end
def pbGetWildBattleBGM(*args); nil; end
def pbGetTrainerBattleBGM(*args); nil; end
def pbGetWildVictoryBGM(*args); nil; end
def pbGetTrainerVictoryBGM(*args); nil; end
def pbGetWildCaptureME(*args); nil; end

#===============================================================================
# Message / UI global functions — collect
#===============================================================================
$collected_messages = []

def pbMessage(msg, commands = nil, cmdIfCancel = 0, skin = nil, defaultCmd = 0)
  $collected_messages.push(msg)
  return 0
end

def pbMessageDisplay(*args); $collected_messages.push(args[1].to_s); 0; end
def pbConfirmMessage(msg); $collected_messages.push(msg); true; end
def pbConfirmMessageSerious(msg); $collected_messages.push(msg); false; end
def pbDisplay(msg); $collected_messages.push(msg); end
def pbWait(*args); end

#===============================================================================
# Misc engine glue
#===============================================================================
def pbGetTimeNow; Time.now; end
def pbGetLanguage; 2; end   # 2 = English

# Game switches/variables — plain hashes with falsy/zero defaults
$game_switches = Hash.new(false)
$game_variables = Hash.new(0)

class SpikeGameTemp
  attr_accessor :in_battle, :in_storage, :in_menu, :battle_rules,
                :encounter_triggered, :encounter_type, :forced_switch,
                :party_levels_before_battle, :party_critical_hits_dealt,
                :party_direct_damage_taken
  def initialize
    @in_battle = false
    @in_storage = false
    @in_menu = false
    @battle_rules = {}
    @party_levels_before_battle = []
    @party_critical_hits_dealt = []
    @party_direct_damage_taken = []
  end
  def add_battle_rule(*args); end
  def clear_battle_rules; @battle_rules = {}; end
  def method_missing(name, *args)
    return args[0] if name.to_s.end_with?("=")
    return nil
  end
  def respond_to_missing?(*); true; end
end
$game_temp = SpikeGameTemp.new

class BlackHoleStats
  def method_missing(name, *args)
    return 0 if !name.to_s.end_with?("=")
    return args[0]
  end
  def respond_to_missing?(*); true; end
end
$stats = BlackHoleStats.new

module Essentials
  VERSION = "21.1"
  ERROR_TEXT = ""
  MKXPZ_VERSION = "spike"
end
