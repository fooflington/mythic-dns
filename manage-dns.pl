#!/usr/bin/env perl -w

use strict;
use LWP::UserAgent;
use Data::Dumper;

use YAML::Tiny;
use JSON;
use MIME::Base64;
use WWW::Form::UrlEncoded::PP qw/build_urlencoded/;

my $in = YAML::Tiny->read(shift);
my $ua = LWP::UserAgent->new;
my %seen;

sub _debug {
    print STDERR ("=== DEBUG ===\n", Dumper(@_), "=== END ===\n") if $ENV{DEBUG} or $in->[0]->{debug};
}

sub _info {
    print STDERR ("INFO: ");
    printf STDERR (@_);
    print STDERR "\n";
}

if($ENV{DEBUG} or $in->[0]->{debug}) {
    use LWP::Debug qw(+);
    $ua->add_handler(
    "request_send",
    sub {
        my $msg = shift;              # HTTP::Message
        $msg->dump( maxlength => 0 ); # dump all/everything
        return;
    }
    );

    $ua->add_handler(
    "response_done",
    sub {
        my $msg = shift;                # HTTP::Message
        $msg->dump( maxlength => 512 ); # dump max 512 bytes (default is 512)
        return;
    }
    );
}

$ua->agent("manage-dns (perl)");
$ua->default_header(
    'Authorization',
    'Basic ' . MIME::Base64::encode($in->[0]->{auth}->{key} . ":" . $in->[0]->{auth}->{secret}, '')
    );



sub get_current_zone($) {
    my $z = shift;
    my $url = $in->[0]->{defaults}->{api} . "/$z/records";
    my $res = $ua->get($url);
    if($res->is_success) {
        my $zone = from_json($res->content);
        _debug($res->content);
        return $zone;
    } else {
        die "Failed to request zone ($z) from API: " . $res->status_line;
    }
}

sub find_record($$$$) {
    my ($data, $type, $host, $value) = @_;
    foreach my $record (@{$data->{records}}) {
        _debug("Comparing", $record, $host, $type, $value);
        if($record->{host} eq $host and $record->{type} eq $type and reformat_data($type, $record) eq $value) {
            # Mark record as seen
            # $record->{_seen}++;
            _debug("Found a record matching $host $type $value");
            return $record;
        }
    }
    _debug("failed to find a record matching: $host $type $value");
    return undef;
}

sub format_record($$$$) {
    my ($zone, $type, $host, $value) = @_;
    my $record = {
        data => $value,
        host => $host,
        ttl => $in->[0]->{defaults}->{ttl}->{$zone},
        type => $type,
    };
    if ($type eq 'MX') {
        my ($pri, $data) = split(/\s+/, $value) or croak("Argh");
        $record->{mx_priority} = $pri;
        $record->{data} = $data;
    }

    return $record;
}

sub reformat_data($$) {
    my ($type, $data) = @_;
    if($type eq 'MX') {
        return sprintf('%d %s', $data->{mx_priority}, $data->{data});
    }

    return $data->{data};
}

sub check_and_update_record($$$$$) {
    my ($zone, $data, $type, $host, $value) = @_;
    my $record = find_record($data, $type, $host, $value);

    my $url = $in->[0]->{defaults}->{api} . "/$zone/records/$host/$type";

    if ($record) {
        # Compare existing record (just the ttl, really!)
        if($record->{ttl} ne $in->[0]->{defaults}->{ttl}->{$zone}) {
            # Update the record
            $record->{ttl} = $in->[0]->{defaults}->{ttl}->{$zone};
            _debug("Update ", $url, $record, to_json($record));
            my $res = $ua->put(
                $url,
                "Content-Type" => "application/json",
                "Content" => to_json({ records => [ $record ] }),
            );
            warn "Failed to update $url: " . $res->status_line unless $res->is_success;
        }
    } else {
        # Create new record
        my $new = format_record($zone, $type, $host, $value);
        _info("Created new record: %s %s %s", $host, $type, $value);
        my $res = $ua->post(
            $url,
            "Content-Type" => "application/json",
            Content => to_json({
                records => [ $new ]
            })
        );
        warn "Failed to create $url: " . $res->status_line . "\n" . $res->content unless $res->is_success;
    }
}

foreach my $z (keys %{$in->[0]->{zones}}) {
    print "--- Handling $z\n";
    my $current = get_current_zone($z);

    my $zone = $in->[0]->{zones}->{$z};
    foreach my $rec (keys %$zone) {
        # print "    - $rec\n";
        foreach my $type (keys %{$zone->{$rec}}) {
            # print "      - $type\n";
            if($type eq 'aliases') {
                # aliases are a set of CNAMEs to the node
                # print "*** Skipping aliases on $rec for $z\n";
                foreach my $alias (@{$zone->{$rec}->{aliases}}) {
                    # _info ("Would create alias for %s -> %s", $alias, $rec);
                    check_and_update_record($z, $current, "CNAME", $alias, $rec);
                }
            } else {
                if(ref($zone->{$rec}->{$type}) eq 'ARRAY') {
                    # multivalue
                    foreach my $value (@{$zone->{$rec}->{$type}}) {
                        check_and_update_record($z, $current, $type, $rec, $value);
                    }
                } else {
                    # single value
                    check_and_update_record($z, $current, $type, $rec, $zone->{$rec}->{$type});
                }
            }
        }

    }
}

# check for unseen records and delete but skip "_template" : true,
