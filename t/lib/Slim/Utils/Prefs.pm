package Slim::Utils::Prefs;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(preferences);
our %GLOBAL = (
    'plugin.sacdplayer' => {},
);
sub preferences {
    my ($ns) = @_;
    return bless { ns => $ns }, 'Slim::Utils::Prefs::Obj';
}
package Slim::Utils::Prefs::Obj;
sub get { my ($s,$k)=@_; return $Slim::Utils::Prefs::GLOBAL{$s->{ns}}{$k}; }
sub set { my ($s,$k,$v)=@_; $Slim::Utils::Prefs::GLOBAL{$s->{ns}}{$k}=$v; }
sub client { my ($s,$c)=@_; return bless { ns => $s->{ns}, client => $c }, 'Slim::Utils::Prefs::Client'; }
package Slim::Utils::Prefs::Client;
sub get { my ($s,$k)=@_; return $Slim::Utils::Prefs::GLOBAL{$s->{ns}}{"client:$k"}; }
sub set { my ($s,$k,$v)=@_; $Slim::Utils::Prefs::GLOBAL{$s->{ns}}{"client:$k"}=$v; }
1;
