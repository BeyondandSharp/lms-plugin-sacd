package Plugins::SACDPlayer::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Plugins::SACDPlayer::Transcoder;

my $prefs = preferences('plugin.sacdplayer');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SACDPLAYER');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/SACDPlayer/settings/basic.html');
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        for my $key (qw(ffmpeg ffprobe helper tag_fallback max_tag_size_mb)) {
            next unless exists $params->{"pref_$key"};
            my $v = $params->{"pref_$key"};
            $v = 0 if !defined $v || $v eq '';
            $v = 32 if $key eq 'max_tag_size_mb' && $v < 1;
            $prefs->set($key, $v);
        }
        $prefs->set('tag_fallback', 'auto')
            unless ($prefs->get('tag_fallback') || '') =~ /^(?:auto|ffprobe|off)$/;
    }

    $params->{prefs} = {
        ffmpeg           => $prefs->get('ffmpeg') || '',
        ffprobe          => $prefs->get('ffprobe') || '',
        helper           => $prefs->get('helper') || '',
        tag_fallback     => $prefs->get('tag_fallback') || 'auto',
        max_tag_size_mb  => $prefs->get('max_tag_size_mb') || 32,
    };
    $params->{status} = Plugins::SACDPlayer::Transcoder->status;
    return $class->SUPER::handler($client, $params);
}

1;
