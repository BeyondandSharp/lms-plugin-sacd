package Plugins::SACDPlayer::Plugin;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Control::Request;

use Plugins::SACDPlayer::Formats;
use Plugins::SACDPlayer::Transcoder;

my $log   = logger('plugin.sacdplayer');

sub initPlugin {
    my $class = shift;

    unless (main::SCANNER) {
        eval { require Plugins::SACDPlayer::Settings; Plugins::SACDPlayer::Settings->new; 1 };
        eval { require Plugins::SACDPlayer::PlayerSettings; Plugins::SACDPlayer::PlayerSettings->new; 1 };
    }

    Plugins::SACDPlayer::Formats->install;

    if (eval { require Slim::Utils::PluginManager; Slim::Utils::PluginManager->isEnabled('Plugins::DSDPlayer::Plugin') }) {
        $log->warn('SACD and DSDPlayer both override DSF/DFF tag readers; disable one of them.');
    }

    unless (main::SCANNER) {
        Slim::Control::Request::subscribe(
            \&initClientForSACD,
            [ ['client'], ['new', 'reconnect'] ],
        );
    }
}

sub postinitPlugin {
    my $class = shift;
    Plugins::SACDPlayer::Formats->install;
    return if main::SCANNER;

    require Plugins::SACDPlayer::Hooks;
    Plugins::SACDPlayer::Hooks->install;
}

sub shutdownPlugin {
    # All overrides live in the LMS process and are restored by a restart.
    return 1;
}

sub initClientForSACD {
    my $request = shift;
    my $client  = $request && $request->client;
    return unless $client;
    Plugins::SACDPlayer::Transcoder->setup($client);
}

# Called by the settings handlers after a preference change.
sub setupTranscoder {
    my ($class, $client) = @_;
    Plugins::SACDPlayer::Transcoder->setup($client);
}

1;
