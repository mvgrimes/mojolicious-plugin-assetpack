package Mojolicious::Plugin::AssetPack;

use Mojo::Base 'Mojolicious::Plugin';
use Mojo::ByteStream;
use Mojo::Util ();
use Mojolicious::Plugin::AssetPack::Asset;
use Mojolicious::Plugin::AssetPack::Preprocessors;
use Cwd            ();
use File::Basename ();
use File::Path     ();
use File::Spec     ();
use constant DEBUG    => $ENV{MOJO_ASSETPACK_DEBUG}    || 0;
use constant NO_CACHE => $ENV{MOJO_ASSETPACK_NO_CACHE} || 0;

our $VERSION = '0.63';

has base_url      => '/packed/';
has headers       => sub { +{} };
has minify        => 0;
has preprocessors => sub { Mojolicious::Plugin::AssetPack::Preprocessors->new };
has out_dir       => '';

has _app => undef;
has _ua  => sub {
  require Mojo::UserAgent;
  Mojo::UserAgent->new(max_redirects => 3);
};

sub add {
  my ($self, $moniker, @files) = @_;

  @files = $self->_expand_wildcards(@files);
  return $self->tap(sub { $self->{files}{$moniker} = \@files }) if NO_CACHE;
  return $self->tap(sub { $self->_assets($moniker => $self->_process($moniker, @files)) }) if $self->minify;
  return $self->tap(sub { $self->_assets($moniker => $self->_process_many($moniker, @files)) });
}

sub fetch {
  my $self = shift;
  my $url  = Mojo::URL->new(shift);
  my $asset
    = $self->_packed("$url") || $self->_handler($url->scheme)->asset_for($url, $self)->in_memory(!$self->out_dir)->save;
  return $asset if @_;    # internal
  return $asset->path;    # documented api
}

sub get {
  my ($self, $moniker, $args) = @_;
  my $assets = $self->_assets($moniker);

  die "Asset '$moniker' is not defined." unless @$assets;
  return @$assets if $args->{assets};
  return map { $_->slurp } @$assets if $args->{inline};
  return map { $self->base_url . $_->basename } @$assets;
}

sub preprocessor {
  my ($self, $name, $args) = @_;
  $args->{extensions} or die "Usage: \$self->preprocessor(\$name => {extensions => [...]})";
  $self->preprocessors->add($_ => $name => $args) for @{$args->{extensions}};
  return $self;
}

sub purge {
  my ($self, $args) = @_;
  my $file_re = $self->minify ? qr/^(.*?)-(\w{32})\.min\.(\w+)$/ : qr/^(.*?)-(\w{32})\.(\w+)$/;
  my ($PACKED, %existing);

  # default to not purging, unless in development mode
  local $args->{always} = $args->{always} // $self->_app->mode eq 'development';

  return $self unless $args->{always};
  die '$app->asset->purge() must be called AFTER $app->asset(...)' unless keys %{$self->{assets} || {}};
  return $self unless $self->out_dir and opendir $PACKED, $self->out_dir;
  $existing{$_} = 1 for grep { $_ =~ $file_re } readdir $PACKED;
  delete $existing{$_->basename} for map {@$_} values %{$self->{assets} || {}};

  for my $file (keys %existing) {
    $self->_unlink_packed($file);
    warn "[ASSETPACK] Purged $file ($!)\n" if DEBUG;
  }

  return $self;
}

sub register {
  my ($self, $app, $config) = @_;
  my $helper = $config->{helper} || 'asset';

  if (eval { $app->$helper }) {
    return $app->log->debug("AssetPack: Helper $helper() is already registered.");
  }

  $self->{assets}       = {};
  $self->{processed}    = {};
  $self->{source_paths} = $self->_build_source_paths($app, $config);

  $self->_app($app);
  $self->_ua->server->app($app);
  $self->_ua->proxy->detect if $config->{proxy};
  $self->headers($config->{headers} || {});
  $self->minify($config->{minify} // $app->mode ne 'development');
  $self->out_dir($self->_build_out_dir($app, $config));
  $self->base_url($config->{base_url}) if $config->{base_url};
  $self->_reloader($app, $config->{reloader}) if $config->{reloader};

  $self->{fallback_assets} = do {
    require Mojo::JSON;
    my $map = File::Spec->catdir($self->out_dir, 'assetpack.json');
    -r $map ? Mojo::JSON::decode_json(Mojo::Util::slurp($map)) : {};
  };

  $self->_load_plugins(@{$config->{plugins} || []});

  if (NO_CACHE) {
    $app->log->info('AssetPack Will rebuild assets on each request in memory');
    $self->out_dir('');
    $self->_assets_from_memory;
  }

  $app->helper(
    $helper => sub {
      return $self if @_ == 1;
      return shift, $self->add(@_) if @_ > 2 and ref $_[2] ne 'HASH';
      return $self->_inject(@_);
    }
  );
}

sub source_paths {
  my $self = shift;
  my $app  = $self->_app;

  if (@_) {
    $self->{source_paths} = shift;
    return $self;
  }
  else {
    return $self->{source_paths} || return $app->static->paths;
  }
}

sub _asset {
  my ($self, $name) = @_;
  my $asset = $self->{asset}{$name} ||= Mojolicious::Plugin::AssetPack::Asset->new;
  $asset->path(File::Spec->catfile($self->out_dir, $name)) unless $asset->path;
  $asset;
}

sub _assets {
  my ($self, $moniker, @assets) = @_;
  $self->{assets}{$moniker} = \@assets if @assets;
  $self->{assets}{$moniker} || [];
}

sub _assets_from_memory {
  my $self    = shift;
  my $headers = $self->headers;

  $self->_app->hook(
    before_routes => sub {
      my $c    = shift;
      my $path = $c->req->url->path;

      return if $c->req->is_handshake or $c->res->code;
      return unless $path->[1] and 0 == index "$path", $self->base_url;
      return unless my $asset = $c->asset->{asset}{$path->[1]};
      return if $asset->{internal};
      my $h = $c->res->headers->last_modified(Mojo::Date->new($^T))
        ->content_type($c->app->types->type($asset->path =~ /\.(\w+)$/ ? $1 : 'txt') || 'text/plain');
      $h->header($_ => $headers->{$_}) for keys %$headers;
      $c->reply->asset($asset);
    }
  );
}

sub _build_out_dir {
  my ($self, $app, $config) = @_;
  my $out_dir = $config->{out_dir};

  if ($out_dir) {
    my $static_dir = Cwd::abs_path(File::Spec->catdir($out_dir, File::Spec->updir));
    push @{$app->static->paths}, $static_dir unless grep { $_ eq $static_dir } @{$app->static->paths};
  }
  elsif (!defined $out_dir) {
    for my $path (@{$app->static->paths}) {
      next unless -w $path;
      $out_dir = File::Spec->catdir($path, 'packed');
      last;
    }
  }

  File::Path::make_path($out_dir) if $out_dir and !-d $out_dir;
  return $out_dir // '';
}

sub _build_source_paths {
  my ($self, $app, $config) = @_;

  return undef unless my $paths = $config->{source_paths};
  return [map { -d $_ ? Cwd::abs_path($_) : $app->home->rel_file($_) } @$paths];
}

sub _expand_wildcards {
  my $self = shift;
  my (@files, %seen);

  for my $file (@_) {
    if (!-e $file and $file =~ /\*/) {
      my @rel = split '/', $file;
      my $glob = pop @rel;

      for my $path (map { File::Spec->catdir($_, @rel) } @{$self->source_paths}) {
        my $cwd = Mojolicious::Plugin::AssetPack::Preprocessors::CWD->new($path);
        push @files, grep { !$seen{$_} } map { join '/', @rel, $_ } sort glob $glob;
      }
    }
    else {
      push @files, $file;
      $seen{$file} = 1;
    }
  }

  return @files;
}

sub _handler {
  my ($self, $moniker) = @_;
  $self->{handler}{$moniker} ||= do {
    my $class = "Mojolicious::Plugin::AssetPack::Handler::" . ucfirst $moniker;
    eval "require $class;1" or die "Could not load $class: $@\n";
    $class->new;
  };
}

sub _inject {
  my ($self, $c, $moniker, $args, @attrs) = @_;
  my $tag_helper = $moniker =~ /\.js/ ? 'javascript' : 'stylesheet';

  if (NO_CACHE) {
    $self->_assets($moniker => $self->_process_many($moniker, @{$self->{files}{$moniker} || []}));
  }

  eval {
    if ($args->{inline}) {
      return $c->$tag_helper(@attrs, sub { join "\n", $self->get($moniker, $args) });
    }
    else {
      return Mojo::ByteStream->new(join "\n", map { $c->$tag_helper($_, @attrs) } $self->get($moniker, $args));
    }
    1;
  } or do {
    $self->_app->log->error($@);
    return Mojo::ByteStream->new(qq(<!-- Asset '$moniker' is not defined\. -->));
  };
}

sub _make_error_asset {
  my ($self, $moniker, $file, $err) = @_;

  $err =~ s!\r!!g;
  $err =~ s!\n+$!!;
  $err = "$file: $err";

  if ($moniker =~ /\.js$/) {
    $err =~ s!'!"!g;
    $err =~ s!\n!\\n!g;
    $err =~ s!\s! !g;
    return "alert('$err');console.log('$err');";
  }
  else {
    $err =~ s!"!'!g;
    $err =~ s!\n!\\A!g;
    $err =~ s!\s! !g;
    return
      qq(html:before{background:#f00;color:#fff;font-size:14pt;position:fixed;padding:20px;z-index:9999;content:"$err";});
  }
}

sub _load_plugins {
  my $self = shift;
  my $app  = $self->_app;
  my $i    = 0;

  while ($i < @_) {
    my $plugin = $_[$i] or last;
    my $args = ref $_[$i + 1] ? $_[$i + 1] : undef;
    unless (eval { $app->plugin($plugin => $args || {}); 1 }) {
      die $@ unless keys %{$self->{fallback_assets}};
      $app->log->warn("AssetPack going into fallback mode." . (DEBUG ? $@ : ''));
    }
    $i += $args ? 2 : 1;
  }
}

sub _packed {
  my $self = shift;
  my $needle = shift or return undef;

  $needle = _name($needle) unless ref $needle;

  for my $path (map { File::Spec->catdir($_, 'packed') } @{$self->_app->static->paths}) {
    opendir my $DH, $path or next;
    for (readdir $DH) {
      next unless /$needle/;
      $path = Cwd::abs_path(File::Spec->catfile($path, $_));
      $self->_app->log->debug("Using existing asset $path") if DEBUG;
      return $self->_asset($_)->path($path)->in_memory(0);
    }
  }

  return undef;
}

sub _process {
  my ($self, $moniker, @sources) = @_;
  my ($name, $ext) = (_name($moniker), _ext($moniker));
  my ($asset, $file, @checksum);
  my $fallback = 0;

  @sources = map {
    my $source = $self->_source_for_url($_);
    push @checksum, $self->preprocessors->checksum(_ext($_), \$source->slurp, $source->path);
    $source;
  } @sources;

  @checksum = (Mojo::Util::md5_sum(join '', @checksum)) if @checksum > 1;
  $asset = $self->_packed($self->minify ? qr{^$name-$checksum[0](\.min)?\.$ext$} : qr{^$name-$checksum[0]\.$ext$});
  return $asset if $asset;

  $file = $self->minify ? "$name-$checksum[0].min.$ext" : "$name-$checksum[0].$ext";
  $asset = $self->{asset}{$file} = Mojolicious::Plugin::AssetPack::Asset->new;
  $asset->in_memory(1)->path(File::Spec->catfile($self->out_dir, $file));

  for my $source (@sources) {
    eval {
      my $content = $source->slurp;
      $self->preprocessors->process(_ext($source->path), $self, \$content, $source->path);
      $asset->content($asset->content . $content);
      1;
    } or do {
      my $e = $@;
      warn "[ASSETPACK] process(@{[$source->path]}) FAIL $e\n" if DEBUG;
      $asset->path(File::Spec->catfile($self->out_dir, "$name-$checksum[0].err.$ext"));
      $asset->content($self->_make_error_asset($moniker, $source->basename, $e || 'Unknown error'));
      $fallback = 1;
      last;
    };
  }

  if ($fallback and $fallback = $self->_packed($self->{fallback_assets}{$file})) {
    $asset = $fallback;
  }

  unless ($self->{hook_added}++) {
    if (!$self->out_dir) {
      $self->_app->log->warn('AssetPack will store assets in memory');
      $self->_assets_from_memory;
    }
    elsif (my $headers = $self->headers) {
      $self->_app->hook(
        after_static => sub {
          my $c    = shift;
          my $path = $c->req->url->path;
          return unless $path->[1] and 0 == index "$path", $self->base_url;
          my $h = $c->res->headers;
          $h->header($_ => $headers->{$_}) for keys %$headers;
        }
      );
    }
  }

  unless ($fallback) {
    $asset->in_memory(!$self->out_dir)->save;
    $self->_app->log->info("Built asset for $moniker");
  }

  $asset;
}

sub _process_many {
  my ($self, $moniker, @files) = @_;
  my $ext = _ext($moniker);
  map { my $name = _name($_); $self->_process("$name.$ext" => $_) } @files;
}

sub _reloader {
  my ($self, $app, $config) = @_;
  my $reloader = $self->_asset('reloader.js');

  return if !$config->{enabled} and $app->mode ne 'development';

  warn "[ASSETPACK] Adding reloader asset and route\n" if DEBUG;
  $reloader->path('reloader.js')->{internal} = 1;
  $self->{assets}{'reloader.js'} = [$reloader];
  push @{$app->renderer->classes}, __PACKAGE__;
  $app->routes->get('/packed/reloader')->to(template => 'packed/reloader', strategy => 'document', %$config);
  $app->routes->websocket('/packed/reloader/ws')->to(
    cb => sub {
      shift->on(message => sub { shift->send('pong'); });
    }
  )->name('assetpack.ws');
}

sub _source_for_url {
  my ($self, $url) = @_;

  if (my $scheme = Mojo::URL->new($url)->scheme) {
    return $self->fetch($url, 'internal');
  }

  my @look_in = (@{$self->source_paths}, @{$self->_app->static->paths});
  my @path = split '/', $url;

  for my $path (map { Cwd::abs_path(File::Spec->catfile($_, @path)) } @look_in) {
    return $self->_asset($_)->path($path)->in_memory(0) if $path and -r $path;
  }

  return $self->_handler('https')->asset_for($url, $self);
}

sub _unlink_packed {
  my ($self, $file) = @_;
  unlink File::Spec->catfile($self->out_dir, $file);
}

# utils
sub _ext { local $_ = File::Basename::basename($_[0]); /\.(\w+)$/ ? $1 : 'unknown'; }

sub _name {
  local $_ = $_[0];
  return do { s![^\w-]!_!g; $_ } if /^https?:/;
  $_ = File::Basename::basename($_);
  /^(.*)\./ ? $1 : $_;
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::AssetPack - Compress and convert css, less, sass, javascript and coffeescript files

=head1 VERSION

0.63

=head1 SYNOPSIS

=head2 Application

  use Mojolicious::Lite;

  # load plugin
  plugin "AssetPack";

  # define assets: $moniker => @real_assets
  app->asset('app.js' => '/js/foo.js', '/js/bar.js', '/js/baz.coffee');
  app->asset->purge; # remove old packed files
  app->start;

See also L<Mojolicious::Plugin::AssetPack::Manual::Assets> for more
details on how to define assets.

=head2 Template

  %= asset 'app.js'
  %= asset 'app.css'

See also L<Mojolicious::Plugin::AssetPack::Manual::Include> for more
details on how to include assets.

=head1 DESCRIPTION

L<Mojolicious::Plugin::AssetPack> is a L<Mojolicious> plugin which can be used
to cram multiple assets of the same type into one file. This means that if
you have a lot of CSS files (.css, .less, .sass, ...) as input, the AssetPack
can make one big CSS file as output. This is good, since it will often speed
up the rendering of your page. The output file can even be minified, meaning
you can save bandwidth and browser parsing time.

The core preprocessors that are bundled with this module can handle CSS and
JavaScript files, written in many languages.

=head1 MANUALS

The documentation is split up in different manuals, for more in-depth
information:

=over 4

=item *

See L<Mojolicious::Plugin::AssetPack::Manual::Assets> for how to define
assets in your application.

=item *

See L<Mojolicious::Plugin::AssetPack::Manual::Include> for how to include
the assets in the template.

=item *

See L<Mojolicious::Plugin::AssetPack::Manual::Modes> for how AssetPack behaves
in different modes.

=item *

See L<Mojolicious::Plugin::AssetPack::Manual::CustomDomain> for how to
serve your assets from a custom host.

=item * 

See L<Mojolicious::Plugin::AssetPack::Preprocessors> for details on the
different (official) preprocessors.

=back

=head1 ENVIRONMENT

=head2 MOJO_ASSETPACK_DEBUG

Set this to get extra debug information to STDERR from AssetPack internals.

=head2 MOJO_ASSETPACK_NO_CACHE

If true, convert the assets each time they're expanded, instead of once at
application start (useful for development).

=head1 HELPERS

=head2 asset

This plugin defined the helper C<asset()>. This helper can be called in
different ways:

=over 4

=item * $self = $c->asset;

This will return the plugin instance, that you can call methods on.

=item * $c->asset($moniker => @real_files);

See L</add>.

=item * $bytestream = $c->asset($moniker, \%args, @attr);

Used to include an asset in a template.

=back

=head1 ATTRIBUTES

=head2 base_url

  $app->plugin("AssetPack" => {base_url => "/packed/"});
  $str = $self->base_url;

This attribute can be used to control where to serve static assets from.

Defaults value is "/packed/".

See L<Mojolicious::Plugin::AssetPack::Manual::CustomDomain> for more details.

NOTE! You need to have a trailing "/" at the end of the string.

=head2 headers

  $hash_ref = $self->headers;
  $self = $self->headers({"Cache-Control" => "max-age=31536000"});

This attribute can hold custom response headers when serving assets.
The default is no headers, but this might change in future release to
include "Cache-Control".

This attribute is EXPERIMENTAL.

=head2 minify

  $bool = $self->minify;
  $app->plugin("AssetPack" => {minify => $bool});

Set this to true if the assets should be minified.

Default is false in "development" L<mode|Mojolicious/mode> and true otherwise.

See also L<Mojolicious::Plugin::AssetPack::Manual::Modes>.

=head2 out_dir

  $str = $self->out_dir;
  $app->plugin("AssetPack" => {out_dir => $str});

Holds the path to the directory where packed files can be written.

Defaults to empty string if no directory can be found, which again results in
keeping all packed files in memory.

=head2 preprocessors

  $obj = $self->preprocessors;

Holds a L<Mojolicious::Plugin::AssetPack::Preprocessors> object.

=head1 METHODS

=head2 add

  $self->add($moniker => @real_files);

Used to define assets.

See L<Mojolicious::Plugin::AssetPack::Manual::Assets> for mode details.

=head2 fetch

  $path = $self->fetch($url);

This method can be used to fetch an asset and store the content to a local
file. The download will be skipped if the file already exists. The return
value is the absolute path to the downloaded file.

=head2 get

  @files = $self->get($moniker);

Returns a list of files which the moniker point to. The list will only
contain one file if L</minify> is true.

See L<Mojolicious::Plugin::AssetPack::Manual::Include/Full control> for mode
details.

=head2 preprocessor

DEPRECATED. Use this instead:

  $self->preprocessors->add($extension => $class => \%attrs);

=head2 purge

  $self = $self->purge({always => $bool});

Used to purge old packed files. This is useful if you want to avoid filling up
L</out_dir> with many versions of the packed file.

C<always> default to true if in "development" L<mode|Mojolicious/mode> and
false otherwise.

This method is EXPERIMENTAL and can change or be removed at any time.

=head2 register

  plugin AssetPack => {
    base_url     => $str,     # default to "/packed"
    headers      => {"Cache-Control" => "max-age=31536000"},
    minify       => $bool,    # compress assets
    plugins      => [...],
    proxy        => "detect", # autodetect proxy settings
    out_dir      => "/path/to/some/directory",
    source_paths => [...],
  };

Will register the C<asset> helper. All L<arguments|/ATTRIBUTES> are optional.

See L<Mojolicious::Plugin::AssetPack::Manual::Modes/Fallback mode> regarding
"plugins".

=head2 source_paths

  $self = $self->source_paths($array_ref);
  $array_ref = $self->source_paths;

This method returns a list of paths to source files. The default is to return
L<Mojolicious::Static/paths> from the current application object, but you can
specify your own paths.

See also L<Mojolicious::Plugin::AssetPack::Manual::Assets/Custom source directories>
for more information.

This method is EXPERIMENTAL and can change, but will most likely not be removed.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

Alexander Rymasheusky

Per Edin - C<info@peredin.com>

Viktor Turskyi

=cut

__DATA__
@@ packed/reloader.js.ep
;window.addEventListener('load', function(e) {
  var xhr, socket, t, reloaded = 0;
  var connect = function() {
    socket = new WebSocket('<%= url_for('assetpack.ws')->userinfo(undef)->to_abs %>'.replace(/^http/, 'ws'));
    socket.onopen = function(e) {
      if (reloaded++) {
        xhr = new XMLHttpRequest();
        xhr.responseType = 'document';
        xhr.open('GET', window.location.href);
        xhr.onreadystatechange = function() {
          if (xhr.readyState != 4) return;
          if (window.console) console.log('[AssetPack] Replacing <head>...</head>');
          document.head.innerHTML = this.responseXML.getElementsByTagName('head')[0].innerHTML;
        };
        xhr.send(null);
      }
      t = setInterval(function() { socket.send('ping'); }, 5000);
    }
    socket.onclose = function() {
      if (t) clearTimeout(t);
      if (window.console) console.log('[AssetPack] Reloading with strategy "<%= $strategy %>" (' + reloaded + ')');
      if ('<%= $strategy %>' == 'document') {
        return window.location = window.location.href;
      }
      else {
        setTimeout(function() { connect() }, 500);
      }
    };
  };
  connect();
});
