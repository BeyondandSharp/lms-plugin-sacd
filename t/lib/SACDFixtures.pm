package SACDFixtures;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(write_dsf write_dff id3_v23 id3_v24 chunk);

sub chunk {
    my ($id, $data) = @_;
    return $id . pack('Q>', length $data) . $data . (length($data) % 2 ? "\0" : '');
}

sub id3_v23 {
    my ($tags, $pic) = @_;
    my $frames = '';
    for my $key (sort keys %$tags) {
        my $fid = $key eq 'COMMENT' ? 'COMM' : $key;
        my $val = $tags->{$key};
        my $data;
        if ($fid eq 'COMM') {
            $data = "\0eng\0" . $val;
        }
        else {
            $data = "\0" . $val;
        }
        $frames .= $fid . pack('N', length $data) . "\0\0" . $data;
    }
    if (defined $pic && length $pic) {
        my $data = "\0image/jpeg\0\3\0" . $pic;
        $frames .= 'APIC' . pack('N', length $data) . "\0\0" . $data;
    }
    my $size = length $frames;
    my $sync = pack('C4',
        ($size >> 21) & 0x7f, ($size >> 14) & 0x7f,
        ($size >> 7) & 0x7f, $size & 0x7f);
    return "ID3\3\0\0" . $sync . $frames;
}

sub id3_v24 {
    my ($tags) = @_;
    my $frames = '';
    for my $fid (sort keys %$tags) {
        my $data = "\3" . $tags->{$fid};
        my $size = length $data;
        my $sync = pack('C4',
            ($size >> 21) & 0x7f, ($size >> 14) & 0x7f,
            ($size >> 7) & 0x7f, $size & 0x7f);
        $frames .= $fid . $sync . "\0\0" . $data;
    }
    my $size = length $frames;
    my $sync = pack('C4',
        ($size >> 21) & 0x7f, ($size >> 14) & 0x7f,
        ($size >> 7) & 0x7f, $size & 0x7f);
    return "ID3\4\0\0" . $sync . $frames;
}

sub write_dsf {
    my ($path, %args) = @_;
    my $fs      = $args{fs} || 2822400;
    my $ch      = $args{channels} || 2;
    my $audio   = $args{audio} || ("\x00" x 8192);
    my $id3     = $args{id3} || '';
    my $samples = int(length($audio) / $ch) * 8;
    my $meta    = 92 + length $audio;
    my $fmt = pack('V6 Q< V2', 1, 0, 2, $ch, $fs, 1, $samples, 4096, 0);
    my $hdr = 'DSD ' . pack('Q<', 28)
        . pack('Q<', $meta + length $id3)
        . pack('Q<', $meta)
        . 'fmt ' . pack('Q<', 52) . $fmt
        . 'data' . pack('Q<', 12 + length $audio) . $audio;
    open my $fh, '>:raw', $path or die $!;
    print $fh $hdr, $id3;
    close $fh;
    return $path;
}

sub write_dff {
    my ($path, %args) = @_;
    my $fs      = $args{fs} || 2822400;
    my $ch      = $args{channels} || 2;
    my $audio   = $args{audio} || ("\x00" x 8192);
    my $id3     = $args{id3} || '';
    my $dst     = $args{dst} ? 1 : 0;
    my $frames  = $args{frames} || 10;

    my $diar = chunk('DIAR', pack('N', length 'DIIN Artist') . 'DIIN Artist');
    my $diti = chunk('DITI', pack('N', length 'DIIN Title') . 'DIIN Title');
    my $fsck = chunk('FS  ', pack('N', $fs));
    my $chnl = chunk('CHNL', pack('n', $ch) . ('SLFT' . 'SRGT') x 1);
    my $cmpr = chunk('CMPR', $dst
        ? 'DST ' . pack('C', 11) . 'DST Encoded'
        : 'DSD ' . pack('C', 14) . 'not compressed');
    my $prop = chunk('PROP', 'SND ' . $fsck . $chnl . $cmpr);

    my $sound;
    if ($dst) {
        my $frte = chunk('FRTE', pack('N n', $frames, 75));
        my $dstf = chunk('DSTF', "\0" x 1000);
        $sound = chunk('DST ', $frte . $dstf);
    }
    else {
        $sound = chunk('DSD ', $audio);
    }

    my $body = 'DSD ' . chunk('FVER', pack('N', 0x01050000))
        . $prop . $sound . chunk('DIIN', $diar . $diti);
    $body .= chunk('ID3 ', $id3) if length $id3;
    my $data = 'FRM8' . pack('Q>', length $body) . $body;
    open my $fh, '>:raw', $path or die $!;
    print $fh $data;
    close $fh;
    return $path;
}

1;
