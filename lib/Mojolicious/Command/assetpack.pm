package Mojolicious::Command::assetpack;

=head1 NAME

Mojolicious::Command::assetpack - Assetpack command

=head1 SYNOPSIS

  # Generate an AssetPack shim for your project
  $ ./script/yourapp assetpack plugin

=head1 DESCRIPTION

L<Mojolicious::Command::assetpack> can run actions for
L<Mojolicious::Plugin::AssetPack>, such as creating a plugin shim.

=cut

use Mojo::Base 'Mojolicious::Command';
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Spec;

=head1 ATTRIBUTES

=head2 description

=head2 usage

=cut

has description => 'Run AssetPack actions';
has usage => sub { shift->extract_usage };

=head1 METHODS

=head2 run

=cut

sub run {
  my ($self, $action, @args) = @_;

  $action ||= 'usage';
  $action = "_action_$action";

  return print $self->usage unless $self->can($action);
  $self->$action(@args);
}

sub _action_plugin {
  my ($self, $plugin) = @_;
  my $path = File::Spec->catfile('lib', split /::/, $plugin);

  die "Cannot generate $plugin without a writable ./lib directory.\n" unless -w 'lib';
  make_path dirname $path unless -d dirname $path;
  open my $PLUGIN, '>', $path or die "Write $path: $!\n";
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;

__DATA__
@@ plugin.ep
package
  <%= $package %>;
use Mojo::Base 'Mojolicious::Plugin';
use constant DEBUG => $ENV{MOJO_ASSETPACK_DEBUG} || 0;

has base_url   => '<%= $app->asset->base_url %>';
has minify     => 0;
has _app       => undef;
has _assetpack => sub { bless {}, '<%= $package %>::SHIM'; };

sub fetch         { shift->_assetpack->fetch(@_) }
sub preprocessors { shift->_assetpack->preprocessors(@_) };
sub purge         { shiff->_assetpack->purge(@_) }

sub add {
  my ($self, $moniker, @files) = @_;

  return $self if $self->{packed}{$moniker};
  return shif->_assetpack->add(@_);
}

sub get {
  my ($self, $moniker, $args) = @_;
  my $assets = $self->{assets}{$moniker};

  die "Asset '$moniker' is not defined." unless @$assets;
  return @$assets if $args->{assets};
  return map { $_->slurp } @$assets if $args->{inline};
  return map { $self->base_url . $_->basename } @$assets;
}

sub register {
  my ($self, $app, $config) = @_;
  my $helper = $config->{helper} || 'asset';

  # Need the real deal
  return $self->plugin('AssetPack', $config) if NO_CACHE;

  if (eval { $app->$helper }) {
    return $app->log->debug("AssetPack: Helper $helper() is already registered.");
  }

  $self->{assets}    = {}; # NEED TO BE CACHED
  $self->{processed} = {}; # NEED TO BE CACHED
  $self->{config}    = $config || {};

  $self->_app($app);
  $self->minify($config->{minify} // $app->mode ne 'development');
  $self->base_url($config->{base_url}) if $config->{base_url};
  $self->_reloader($app, $config->{reloader}) if $config->{reloader};

  $app->helper(
    $helper => sub {
      return $self if @_ == 1;
      return shift, $self->add(@_) if @_ > 2 and ref $_[2] ne 'HASH';
      return $self->_inject(@_);
    }
  );
}

package
  <%= $package %>::SHIM;

1;
