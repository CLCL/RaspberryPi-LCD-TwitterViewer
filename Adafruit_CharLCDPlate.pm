package Adafruit_CharLCDPlate;

# Raspberry Pi用Adafruit RGB-backlit LCD plateのPythonライブラリ
# https://github.com/adafruit/Adafruit-Raspberry-Pi-Python-Code/blob/e28539734dfbd6965395f0f0478ecad44ca0eaea/Adafruit_CharLCDPlate/Adafruit_CharLCDPlate.py
# から文字の表示とバックライトの変更の部分だけ最低限移植
# Perl用I2C/SMBusアクセスライブラリHiPiを使用
# http://raspberry.znix.com/p/install.html
#
# This is essentially a complete rewrite, but the calling syntax
# and constants are based on code from lrvick and LiquidCrystal.
# lrvic - https://github.com/lrvick/raspi-hd44780/blob/master/hd44780.py
# LiquidCrystal - https://github.com/arduino/Arduino/blob/master/libraries/LiquidCrystal/LiquidCrystal.cpp


use strict;
use warnings;
use HiPi::Device::I2C;
use HiPi::BCM2835::I2C;

use constant {
    # Port expander registers,
    # ポートエキスパンダ（MCP23017） のレジスタ
    MCP23017_IOCON_BANK0    => 0x0A, # IOCON when Bank 0 active / Bank 0がアクティブ時のIOCONレジスタアドレス
    MCP23017_IOCON_BANK1    => 0x15, # IOCON when Bank 1 active / Bank 1がアクティブ時のIOCONレジスタアドレス
    # These are register addresses when in Bank 1 only:,
    # 以下は、Bank 1がアクティブのみ有効なレジスタアドレス
    MCP23017_GPIOA          => 0x09,
    MCP23017_IODIRB         => 0x10,
    MCP23017_GPIOB          => 0x19,
    
    # Port expander input pin definitions
    # ポートエキスパンダ（MCP23017） の入力ピンの定義
    SELECT                  => 0,
    RIGHT                   => 1,
    DOWN                    => 2,
    UP                      => 3,
    LEFT                    => 4,
    
    # LED colors
    # LCDパネルのバックライトLEDの色
    OFF                     => 0x00,
    RED                     => 0x01,
    GREEN                   => 0x02,
    BLUE                    => 0x04,
};
use constant {
    YELLOW                  => RED + GREEN,
    TEAL                    => GREEN + BLUE,
    VIOLET                  => RED + BLUE,
    WHITE                   => RED + GREEN + BLUE,
    ON                      => RED + GREEN + BLUE,
        
    # LCD Commands
    # LCD（ポートエキスパンダの先につながっているキャラクタLCDドライバHD44780用の命令）
    LCD_CLEARDISPLAY        => 0x01,
    LCD_RETURNHOME          => 0x02,
    LCD_ENTRYMODESET        => 0x04,
    LCD_DISPLAYCONTROL      => 0x08,
    LCD_CURSORSHIFT         => 0x10,
    LCD_FUNCTIONSET         => 0x20,
    LCD_SETCGRAMADDR        => 0x40,
    LCD_SETDDRAMADDR        => 0x80,
    
    # Flags for display on/off control
    # ディスプレイOn/Offコントロールフラグ（HD44780用）3bits
    LCD_DISPLAYON           => 0x04,
    LCD_DISPLAYOFF          => 0x00,
    LCD_CURSORON            => 0x02,
    LCD_CURSOROFF           => 0x00,
    LCD_BLINKON             => 0x01,
    LCD_BLINKOFF            => 0x00,
    
    # Flags for display entry mode
    # ディスプレイエントリモードフラグ（HD44780用）2bits
    LCD_ENTRYRIGHT          => 0x00,
    LCD_ENTRYLEFT           => 0x02,
    LCD_ENTRYSHIFTINCREMENT => 0x01,
    LCD_ENTRYSHIFTDECREMENT => 0x00,
    
    # Flags for display/cursor shift
    # カーソル/ディスプレイシフトフラグ（HD44780用）2bits
    LCD_DISPLAYMOVE => 0x08,
    LCD_CURSORMOVE  => 0x00,
    LCD_MOVERIGHT   => 0x04,
    LCD_MOVELEFT    => 0x00,
};

sub new {
  my $class = shift;
  my %args = ( @_ );
  my $self = {};
  $self->{addr} = 0x20;
  $self->{i2c} = HiPi::Device::I2C->new( address => $self->{addr});
  
  $self->{color} = {
      OFF    => OFF,
      RED    => RED,
      GREEN  => GREEN,
      BLUE   => BLUE,
      YELLOW => YELLOW,
      TEAL   => TEAL,
      VIOLET => VIOLET,
      WHITE  => WHITE,
      ON     => ON,
  };

  # The LCD data pins (D4-D7) connect to MCP pins 12-9 (PORTB4-1), in
  # that order.  Because this sequence is 'reversed,' a direct shift
  # won't work.  This table remaps 4-bit data values to MCP PORTB
  # outputs, incorporating both the reverse and shift.
  # LCDモジュールのDATAピン（D4-D7）は、MCP23017の12-9ピン（PORTB4-1）
  # にこの順番で結線されている。逆順になっているので、通常のシフト
  # はうまく動かない。次のテーブルは、シフト・反転用に対応したMCP23017
  # のPORTBに出力する値を再定義します。

  $self->{flip} = [
    0b00000000, 0b00010000, 0b00001000, 0b00011000,
    0b00000100, 0b00010100, 0b00001100, 0b00011100,
    0b00000010, 0b00010010, 0b00001010, 0b00011010,
    0b00000110, 0b00010110, 0b00001110, 0b00011110,
  ];
  
  # The speed of LCD accesses is inherently limited by I2C through the
  # port expander.  A 'well behaved program' is expected to poll the
  # LCD to know that a prior instruction completed.  But the timing of
  # most instructions is a known uniform 37 mS.  The enable strobe
  # can't even be twiddled that fast through I2C, so it's a safe bet
  # with these instructions to not waste time polling (which requires
  # several I2C transfers for reconfiguring the port direction).
  # The D7 pin is set as input when a potentially time-consuming
  # instruction has been issued (e.g. screen clear), as well as on
  # startup, and polling will then occur before more commands or data
  # are issued.
  # LCDアクセスの速度は、I2Cで接続されるポートエキスパンダ（MCP23017）
  # で制限されます。
  # 「行儀のよいプログラム」は先に実行した命令の完了をLCDからポーリング
  # します。しかし、ほとんどのプログラムは37msのウェイトで済ませています。
  # enable信号は、I2Cによってそれほど速く切り替えることができません。
  # したがって、それは時間ポーリング（それはポート方向の再構成のために、
  # いくつかのI2Cが移ることを必要とする）を浪費しないためにこれらの指
  # 示を備えた安全策です。
  # D7ピンは、潜在的に時間を消費する命令が出された場合（例えばスクリー
  # ンクリア）だけでなく、起動時などに入力に設定され、複数のコマンド
  # あるいはデータが出される場合、ポーリングの必要が生じます。
  $self->{pollables} = [ LCD_CLEARDISPLAY, LCD_RETURNHOME ];


  # I2C is relatively slow.  MCP output port states are cached
  # so we don't need to constantly poll-and-change bit states.
  # self.porta, self.portb, self.ddrb = 0, 0, 0b00010000
  # I2Cのレスポンスは比較的遅い。MCP23017の出力ポートの変更状態
  # はキャッシュ（$self->{poata}, $self->{portb}, $self->{ddrb}）
  # で管理するので、書き込み後いちいちポーリングして確認する
  # 必要はありません。
  $self->{porta} = 0;
  $self->{portb} = 0;
  $self->{ddrb}  = 0b00010000;

  # Set MCP23017 IOCON register to Bank 0 with sequential operation.
  # If chip is already set for Bank 0, this will just write to OLATB,
  # which won't seriously bother anything on the plate right now
  # (blue backlight LED will come on, but that's done in the next
  # step anyway).
  # MCP23017のIOCONレジスタをBank0、シーケンシャル処理を有効に設定し
  # ます。Bank 1になっている想定で決め打ちのアドレスで書き込むため、
  # すでにMCP23017チップがBank 0に切り替わっていた場合、OLATBに書き
  # 込まれることになりますが、特に問題はありません（青いバックライ
  # トが点灯しますが、次のステップで解決します）。
  # 0x80 BANK 0=bank 0を選択
  # 0x20 SEQOP シーケンシャルオペレーション 0=アドレスのオートインクリメントをする
  $self->{i2c}->smbus_write_byte_data( MCP23017_IOCON_BANK1, 0 );

  # Brute force reload ALL registers to known state.  This also
  # sets up all the input pins, pull-ups, etc. for the Pi Plate.
  # 総当たりですべてのレジスタに設定を読み込ませます。また、
  # Pi Plateの入力ピン設定や、プルアップ設定も行います。

  $self->{i2c}->smbus_write_i2c_block_data(0, [
    0b00111111,       # IODIRA    R+G LEDs=outputs, buttons=inputs
    $self->{ddrb} ,   # IODIRB    LCD D7=input, Blue LED=output
    0b00111111,       # IPOLA     Invert polarity on button inputs
    0b00000000,       # IPOLB
    0b00000000,       # GPINTENA  Disable interrupt-on-change
    0b00000000,       # GPINTENB
    0b00000000,       # DEFVALA
    0b00000000,       # DEFVALB
    0b00000000,       # INTCONA
    0b00000000,       # INTCONB
    0b00000000,       # IOCON
    0b00000000,       # IOCON
    0b00111111,       # GPPUA     Enable pull-ups on buttons
    0b00000000,       # GPPUB
    0b00000000,       # INTFA
    0b00000000,       # INTFB
    0b00000000,       # INTCAPA
    0b00000000,       # INTCAPB
    $self->{porta},   # GPIOA
    $self->{portb},   # GPIOB
    $self->{porta},   # OLATA     0 on all outputs; side effect of
    $self->{portb}    # OLATB     turning on R+G+B backlight LEDs.
  ]);

  # Switch to Bank 1 and disable sequential operation.
  # From this point forward, the register addresses do NOT match
  # the list immediately above.  Instead, use the constants defined
  # at the start of the class.  Also, the address register will no
  # longer increment automatically after this -- multi-byte
  # operations must be broken down into single-byte calls.
  # MCP23017をBank 1に切り替えて、シーケンシャル処理を無効にします。
  # これ以降は、レジスタのアドレスはこのメソッドの最初のレジスタの順番と
  # 一致しません。このメソッドの最初で定義した定数を使うこと。
  # 更に、アドレスレジスタは、これ以降は自動的にインクリメントしません。
  # マルチバイトの操作は、シングルバイトの呼び出しに分割処理する必要
  # があります。
  # 0x80 BANK 1=bank 1を選択
  # 0x20 SEQOP シーケンシャルオペレーション 1=アドレスのオートインクリメントしない
  $self->{i2c}->smbus_write_byte_data( MCP23017_IOCON_BANK0, 0b10100000);
  
  $self->{displayshift}   = (LCD_CURSORMOVE | LCD_MOVERIGHT);
  $self->{displaymode}    = (LCD_ENTRYLEFT  | LCD_ENTRYSHIFTDECREMENT);
  $self->{displaycontrol} = (LCD_DISPLAYON  | LCD_CURSOROFF | LCD_BLINKOFF);
  
  return bless $self, $class;
}

sub init {
  my $self = shift;
  $self->write(0x33); # Init
  $self->write(0x32); # Init
  $self->write(0x28); # 2 line 5x8 matrix
                      # 0x20 Function set
                      # 0x10 DL データ長 0=4-bit length
                      # 0x08 NL 行数 1=2行
                      # 0x04 F フォント 0=5x8 dotsフォント
  $self->write(LCD_CLEARDISPLAY);
  $self->write(LCD_CURSORSHIFT    | $self->{displayshift});
  $self->write(LCD_ENTRYMODESET   | $self->{displaymode});
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
  $self->write(LCD_RETURNHOME);
}

# ----------------------------------------------------------------------
# Write operations

# Low-level 4-bit interface for LCD output.  This doesn't actually
# write data, just returns a byte array of the PORTB state over time.
# Can concatenate the output of multiple calls (up to 8) for more
# efficient batch write.
# LCD出力用のローレベル4bitインタフェース。配列にあるbyteデータをPORTBへ
# 直接書き込めないので、4bitデータの4回書き込みに変換する。
# まとめて書き込む場合最大8個連結することができる。
sub out4 {
  my $self    = shift;
  my $bitmask = shift;
  my $value   = shift;
  my $hi = $bitmask | $self->{flip}->[ $value >> 4 ];
  my $lo = $bitmask | $self->{flip}->[ $value & 0x0F];
  return [ $hi | 0b00100000, $hi, $lo | 0b00100000, $lo];
}

# Write byte, list or string value to LCD
# LCDに設定値の配列または文字列を書き込む

sub write {
  my $self = shift;
  my $value= shift;
  my $char_mode = shift || 0;
  # """ Send command/data to LCD """
  
  # If pin D7 is in input state, poll LCD busy flag until clear.
  # もしD7ピンがinputになってるなら、LCDのbusyフラグ（D7ピン）がCLEARになるまでポーリングする。
  if ($self->{ddrb} & 0b00010000 ) {
    my $lo = ( $self->{portb} & 0b00000001) | 0b01000000;
    my $hi = $lo | 0b00100000; # E=1 (strobe)
    $self->{i2c}->smbus_write_byte_data( MCP23017_GPIOB, $lo);
    while (1) {
      # Strobe high (enable)
      $self->{i2c}->smbus_write_byte_data( MCP23017_GPIOB, $hi );
      my $bits = $self->{i2c}->smbus_read_byte();
      # Strobe low, high, low.  Second nybble (A3) is ignored.
      $self->{i2c}->smbus_write_block_data( MCP23017_GPIOB, [$lo, $hi, $lo]);
      last if ( $bits & 0b00000010) == 0; # D7=0, not busy
    }
    $self->{portb} = $lo;
    
    # Polling complete, change D7 pin to output
    # ポーリングが終わったら、D7ピンをoutputに変更する
    $self->{ddrb} &= 0b11101111;
    $self->{i2c}->smbus_write_byte_data( MCP23017_IODIRB, $self->{ddrb});
  }  
  my $bitmask = $self->{portb} & 0b00000001;
  $bitmask |= 0b10000000 if $char_mode; # Set data bit if not a command
  
  # If string or list, iterate through multiple write ops
  # 引数が文字列または配列のリファレンスの場合、複数書き込みとして処理する
  if ( ( $value ^ $value ) ne '0' ) { # 文字列
    my $last = length($value) - 1;
    my $data = [];
    my $i = 0;
    foreach my $v ( split (//, $value) ) {
      # Append 4 bytes to list representing PORTB over time.
      # First the high 4 data bits with strobe (enable) set
      # and unset, then same with low 4 data bits (strobe 1/0).
      # 表わすPORTBを時間にわたってリストするために4バイトを追加してください。
      # 最初に、strobe(Enable)を1/0に設定した上位4bitデータ、
      # その後、下位4bitデータ(strobe 1/0)
      # （つまり8bitデータを4回に分けて送る:MCPとLCDのデータ線が4bitなため）
      push @$data, @{$self->out4($bitmask, ord($v))};
      # I2C block data write is limited to 32 bytes max.
      # If limit reached, write data so far and clear.
      # Also do this on last byte if not otherwise handled.
      # I2Cブロック・データ書き込みは最大32バイトに制限されています。
      # 限界が達した場合は、ここまでのデータを書いて空にしてください。
      # 限界でない場合でも、処理されていないデータがあれば、最後のバイトで
      # 書き込みを行ってください。
      if ( ( $#{$data} >= 31 ) || ($i == $last) ) {
        $self->{i2c}->smbus_write_block_data( MCP23017_GPIOB, $data );
        $self->{portb} = $data->[-1]; # Save state of last byte out
        $data = [];                   # Clear list for next iteration
      }
      $i++;
    }
  }
  elsif ( ref $value eq 'ARRAY' ) { # 配列のリファレンス
    ## Same as above, but for list instead of string
    ## 上と同じルーチンだけど配列用の処理として用意
    my $last = length($value) - 1;
    my $data = [];
    my $i = 0;
    foreach my $v ( @$value ) {
      push @$data, @{$self->out4($bitmask, $v)};
      if ( ( $#{$data} >= 31) || ($i == $last) ) {
        $self->{i2c}->smbus_write_block_data( MCP23017_GPIOB, $data );
        $self->{portb} = $data->[-1]; # Save state of last byte out
        $data = [];                   # Clear list for next iteration
      }
      $i++;
    }
  }
  else {
    # Single byte
    # シングルバイト
    my $data = $self->out4($bitmask, $value);
    $self->{i2c}->smbus_write_block_data( MCP23017_GPIOB, $data );
    $self->{portb} = $data->[-1];
  }
  # If a poll-worthy instruction was issued, reconfigure D7
  # pin as input to indicate need for polling on next call.
  # ポーリング結果で、ポーリング指示が出された場合は、次の呼び出しでポーリングする必要
  # があるので、D7ピンを入力に設定する。
  if ( (!$char_mode) && (grep {$_ eq $value } @{$self->{pollables}} ) ) {
    $self->{ddrb} |= 0b00010000;
    $self->{i2c}->smbus_write_byte_data( MCP23017_IODIRB, $self->{ddrb} ); 
  }
}

# ----------------------------------------------------------------------
# Utility methods

sub begin {
  my $self  = shift;
  my $cols  = shift;
  my $lines = shift;
  $self->{currline} = 0;
  $self->{numlines} = $lines;
  $self->clear();
}

# Puts the MCP23017 back in Bank 0 + sequential write mode so
# that other code using the 'classic' library can still work.
# Any code using this newer version of the library should
# consider adding an atexit() handler that calls this.
sub stop {
  my $self = shift;
  $self->{porta} = 0b11000000;  # Turn off LEDs on the way out
  $self->{portb} = 0b00000001;
  HiPi::BCM2835::I2C->delay(15);
  $self->{i2c}->smbus_write_byte_data( MCP23017_IOCON_BANK1, 0);
  $self->{i2c}->smbus_write_i2c_block_data(0, [
    0b00111111,     # IODIRA
    $self->{ddrb},  # IODIRB
    0b00000000,     # IPOLA
    0b00000000,     # IPOLB
    0b00000000,     # GPINTENA
    0b00000000,     # GPINTENB
    0b00000000,     # DEFVALA
    0b00000000,     # DEFVALB
    0b00000000,     # INTCONA
    0b00000000,     # INTCONB
    0b00000000,     # IOCON
    0b00000000,     # IOCON
    0b00111111,     # GPPUA
    0b00000000,     # GPPUB
    0b00000000,     # INTFA
    0b00000000,     # INTFB
    0b00000000,     # INTCAPA
    0b00000000,     # INTCAPB
    $self->{porta}, # GPIOA
    $self->{portb}, # GPIOB
    $self->{porta}, # OLATA
    $self->{portb},
 ]); # OLATB
}

sub clear {
  my $self = shift;
  $self->write(LCD_CLEARDISPLAY);
}

sub home {
  my $self = shift;
  $self->write(LCD_RETURNHOME);
}

sub setCursor {
  my $self = shift;
  my $col  = shift;
  my $row  = shift;
  $self->{row_offsets} = [ 0x00, 0x40, 0x14, 0x54 ];
  if ( $row > $self->{numlines} ) {
    $row = $self->{numlines} - 1;
  }
  elsif ( $row < 0 ) {
    $row = 0;
  }
  $self->write(LCD_SETDDRAMADDR | ($col + $self->{row_offsets}->[$row]));
}

sub display {
  my $self = shift;
  #""" Turn the display on (quickly) """
  $self->{displaycontrol} |= LCD_DISPLAYON;
  $self->write( LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub noDisplay {
  my $self = shift;
  #""" Turn the display off (quickly) """
  $self->{displaycontrol} &= ~LCD_DISPLAYON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub cursor {
  my $self = shift;
  #""" Underline cursor on """
  $self->{displaycontrol} |= LCD_CURSORON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub ToggleCursor {
  #""" Toggles the underline cursor On/Off """
  my $self = shift;
  $self->{displaycontrol} ^= LCD_CURSORON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub blink {
  #""" Turn on the blinking cursor """
  my $self = shift;
  $self->{displaycontrol} |= LCD_BLINKON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub noBlink {
  #""" Turn off the blinking cursor """
  my $self = shift;
  $self->{displaycontrol} &= ~LCD_BLINKON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub ToggleBlink {
  #""" Toggles the blinking cursor """
  my $self = shift;
  $self->{displaycontrol} ^= LCD_BLINKON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub scrollDisplayLeft {
  #""" These commands scroll the display without changing the RAM """
  my $self = shift;
  my $displayshift = LCD_DISPLAYMOVE | LCD_MOVELEFT;
  $self->write(LCD_CURSORSHIFT | $displayshift);
}

sub scrollDisplayRight {
  #""" These commands scroll the display without changing the RAM """
  my $self = shift;
  my $displayshift = LCD_DISPLAYMOVE | LCD_MOVERIGHT;
  $self->write(LCD_CURSORSHIFT | $displayshift);
}

sub leftToRight {
  #""" This is for text that flows left to right """
  my $self = shift;
  my $displaymode |= LCD_ENTRYLEFT;
  $self->write(LCD_ENTRYMODESET | $displaymode);
}

sub rightToLeft {
  #""" This is for text that flows right to left """
  my $self = shift;
  my $displaymode &= ~LCD_ENTRYLEFT;
  $self->write(LCD_ENTRYMODESET | $displaymode);
}

sub noCursor {
  my $self = shift;
  #""" Underline cursor off """
  $self->{displaycontrol} &= ~LCD_CURSORON;
  $self->write(LCD_DISPLAYCONTROL | $self->{displaycontrol});
}

sub autoscroll {
  my $self = shift;
  #""" This will 'right justify' text from the cursor """
  $self->{displaymode} |= LCD_ENTRYSHIFTINCREMENT;
  $self->write(LCD_ENTRYMODESET | $self->{displaymode});
}

sub noAutoscroll {
  my $self = shift;
  #""" This will 'left justify' text from the cursor """
  $self->{displaymode} &= ~LCD_ENTRYSHIFTINCREMENT;
  $self->write(LCD_ENTRYMODESET | $self->{displaymode});
}
sub message {
  my $self = shift;
  my $text = shift;
  # """ Send string to LCD. Newline wraps to second line"""
  my @lines = split(/\n/, $text); # Split at newline(s)
  my $i = 0;
  foreach my $line ( @lines ) {  # For each substring...
    if ( $i > 0 ) {               # If newline(s),
      $self->write( 0xC0 );       #  set DDRAM address to 2nd line
    }
    $self->write( $line, 1 );  # Issue substring
    $i++;
  }
}

sub backlight {
  my $self  = shift;
  my $color = shift;
  my $c     = ~$color;
  $self->{porta} = ($self->{porta} & 0b00111111) | (($c & 0b011) << 6);
  $self->{portb} = ($self->{portb} & 0b11111110) | (($c & 0b100) >> 2);
  # Has to be done as two writes because sequential operation is off.
  $self->{i2c}->smbus_write_byte_data( MCP23017_GPIOA, $self->{porta});
  $self->{i2c}->smbus_write_byte_data( MCP23017_GPIOB, $self->{portb});
}

# Read state of single button
sub buttonPressed {
  my $self = shift;
  my $b    = shift;
  return ($self->{i2c}->smbus_read_byte_data(MCP23017_GPIOA) >> $b) & 1;
}

# Read and return bitmask of combined button state
sub buttons {
  my $self = shift;
  return $self->{i2c}->smbus_read_byte_data(MCP23017_GPIOA) & 0b11111;
}

1;
