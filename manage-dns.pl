#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use Data::Dumper;

use YAML::Tiny;
use JSON;
use MIME::Base64;
use WWW::Form::UrlEncoded::PP qw/build_urlencoded/;

my $in = YAML::Tiny->read(shift);
my $ua = LWP::UserAgent->new;
my %seen;
my $DRY_RUN = $ENV{DRY_RUN};

sub _debug {
    print STDERR ("=== DEBUG ===\n", Dumper(@_), "=== END ===\n") if $ENV{DEBUG} or $in->[0]->{debug};
}

sub _info {
    print STDERR ("INFO: ");
    printf STDERR (@_);
    print STDERR "\n";
}

sub _notice {
    print STDERR ("NOTICE: ");
    printf STDERR (@_);
    print STDERR "\n";
}

my %supported_types = (
    A => "yes",
    AAAA => "yes",
    CAA => "yes",
    CNAME => "yes",
    DNAME => "yes",
    MX => "yes",
    NS => "yes",
    PTR => "yes",
    SSHFP => "yes",
    SRV => "yes",
    TLSA => "yes",
    TXT => "yes",
);
sub is_unsupported($) {
    my $type = shift;
    return "Unknown type" unless defined $supported_types{$type};
    return undef if $supported_types{$type} eq 'yes';
    return $supported_types{$type};
}

_notice("Dry run - no changes will be applied") if ${DRY_RUN};

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
            $seen{$record} = 1;
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
        my ($pri, $data) = split(/\s+/, $value);
        $record->{mx_priority} = $pri;
        $record->{data} = $data;
    } elsif ($type eq 'SRV') {
        # pri weight port data
        my ($pri, $weight, $port, $data) = split(/\s+/, $value);
        $record->{srv_priority} = $pri;
        $record->{srv_weight} = $weight;
        $record->{srv_port} = $port;
        $record->{data} = $data;
    } elsif ($type eq 'CAA') {
        my ($flags, $property, $data) = split(/\s+/, $value);
        $record->{caa_flags} = $flags;
        $record->{caa_property} = $property;
        $record->{caa_tag} = $property;
        $record->{data} = $data;
    } elsif ($type eq 'SSHFP') {
        my ($algo, $keytype, $data) = split(/\s+/, $value);
        $record->{sshfp_type} = $keytype;
        $record->{sshfp_algorithm} = $algo;
        $record->{data} = $data;
    } elsif ($type eq 'TLSA') {
        my ($usage, $selector, $matching, $data) = split(/\s+/, $value);
        $record->{tlsa_usage} = $usage;
        $record->{tlsa_selector} = $selector;
        $record->{tlsa_matching} = $matching;
        $record->{data} = $data;
    }

    return $record;
}

sub reformat_data($$) {
    my ($type, $data) = @_;
    if($type eq 'MX') {
        return sprintf('%d %s', $data->{mx_priority}, $data->{data});
    } elsif($type eq 'SRV') {
        return sprintf('%d %d %d %s',
            $data->{srv_priority},
            $data->{srv_weight},
            $data->{srv_port},
            $data->{data}
        );
    } elsif($type eq 'CAA') {
        return sprintf('%d %s %s',
            $data->{caa_flags},
            $data->{caa_property} || $data->{caa_tag},
            $data->{data}
        );
    } elsif($type eq 'SSHFP') {
        return sprintf('%d %d %s',
            $data->{sshfp_algorithm},
            $data->{sshfp_type},
            $data->{data},
        );
    } elsif($type eq 'TLSA') {
        return sprintf('%d %d %d %s',
            $data->{tlsa_usage},
            $data->{tlsa_selector},
            $data->{tlsa_matching},
            $data->{data},
        );
    }

    return $data->{data};
}

sub check_and_update_record($$$$$) {
    my ($zone, $data, $type, $host, $value) = @_;
    if(my $err = is_unsupported($type)) {
        warn ("WARNING: Unable to process $host $type: $err");
        return;
    }

    # _info("Considering %s %s %s", $host, $type, $value);
    my $record = find_record($data, $type, $host, $value);

    my $url = $in->[0]->{defaults}->{api} . "/$zone/records/$host/$type";

    if ($record) {
        # Compare existing record (just the ttl, really!)
        if($record->{ttl} ne $in->[0]->{defaults}->{ttl}->{$zone}) {
            # Update the record
            $record->{ttl} = $in->[0]->{defaults}->{ttl}->{$zone};
            _debug("Update ", $url, $record, to_json($record));
            unless ($DRY_RUN) {
                my $res = $ua->put(
                    $url,
                    "Content-Type" => "application/json",
                    "Content" => to_json({ records => [ $record ] }),
                );
                warn "Failed to update $url: " . $res->status_line unless $res->is_success;
            }
        }
    } else {
        # Create new record
        my $new = format_record($zone, $type, $host, $value);
        _notice("Created new record: %s %s %s", $host, $type, $value);
        _debug($new);
        unless ($DRY_RUN) {
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
}

sub delete_record($$) {
    my ($zone, $record) = @_;
    return if $DRY_RUN;

    my $url = $in->[0]->{defaults}->{api} . "/$zone/records/$record->{host}/$record->{type}?host=$record->{host}&data=$record->{data}";
    my $res = $ua->delete($url);
    warn "Failed to delete $url: " . $res->status_line . "\n" . $res->content unless $res->is_success;
}

foreach my $z (keys %{$in->[0]->{zones}}) {
    _info("Processing %s", $z);
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

    _info("Checking for records to delete");
    foreach my $record (@{$current->{records}}) {
        unless (defined $seen{$record}) {
            # _info("Considering %s %s", $record->{host}, $record->{type});
            my $skip;
            $skip = 1 if is_unsupported($record->{type});
            if ($in->[0]->{ignore}->{$z}->{$record->{host}}) {
                # check if type is specified
                if(keys %{$in->[0]->{ignore}->{$z}->{$record->{host}}}) {
                    foreach my $type (keys %{$in->[0]->{ignore}->{$z}->{$record->{host}}}) {
                        if($type eq $record->{type}) {
                            # _info("Skipping %s %s", $record->{host}, $record->{type});
                            $skip = 1;
                        }
                    }
                } else {
                    #_info("Skipping %s *[%s]", $record->{host}, $record->{type});
                    $skip = 1;
                }
            }
            unless ($skip) {
                _notice("Delete %s %s %s", $record->{host}, $record->{type}, $record->{data});
                delete_record($z, $record);
            }
        }
    }
    _info("Finished processing %s", $z);
}
