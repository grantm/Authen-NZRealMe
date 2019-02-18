#!perl

use strict;
use warnings;

use Test::More;
use FindBin;
use File::Spec;
use lib File::Spec->catdir($FindBin::Bin, 'test-lib');

use AuthenNZRealMeTestHelper;
use AuthenNZRealMeSigTestHelper;
use Authen::NZRealMe;
use XML::LibXML;
use Digest::SHA     qw(sha1);
use MIME::Base64    qw(encode_base64);

my $dsig_ns       = 'http://www.w3.org/2000/09/xmldsig#';
my $uri_exc_c14n  = 'http://www.w3.org/2001/10/xml-exc-c14n#';
my $uri_rsa_sha1  = 'http://www.w3.org/2000/09/xmldsig#rsa-sha1';
my $uri_env_sig   = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature';
my $uri_sha1      = 'http://www.w3.org/2000/09/xmldsig#sha1';

my $dispatcher  = 'Authen::NZRealMe';
my $sig_class   = $dispatcher->class_for('xml_signer');

ok($INC{'Authen/NZRealMe/XMLSig.pm'}, "loaded Authen::NZRealMe::XMLSig module");

my $signer = $sig_class->new();
isa_ok($signer, 'Authen::NZRealMe::XMLSig');
is($signer->id_attr, undef, 'no default ID attribute name');

my $xml = '<assertion id="onetwothree"><attribute name="surname">Bloggs</attribute></assertion>';

my $target_id = 'onetwofour';

my $signed = eval{
    $signer->sign($xml, $target_id);
};

is($signed, undef, 'failed to sign doc');
like("$@", qr{Can't find element}, 'because no match for ref URI');


$target_id = 'onetwothree';
$signer = $sig_class->new();
$signed = eval{
    $signer->sign($xml, $target_id);
};

is($signed, undef, 'failed to sign doc');
like("$@", qr{signing key must be set}, 'because no signing key');


my $key_file = test_conf_file('sp-sign-key.pem');
ok(-e $key_file, "test key file exists: $key_file");

$signer = $sig_class->new(
    key_file  => $key_file,
);

$signed = eval{
    $signer->sign($xml, $target_id);
};

is("$@", '', 'signed doc');
like($signed, qr{\A<.*>\z}s, 'return value look like XML');

my $parser = XML::LibXML->new();
my $dom = $parser->parse_string($signed);
my $doc = $dom->getDocumentElement();
my $xc  = XML::LibXML::XPathContext->new($dom);
$xc->registerNs( DSIG => $dsig_ns );

is($doc->nodeName, 'assertion', 'parsed signed assertion');

my @children = $xc->findnodes('/*/*');
is(scalar(@children), 2, 'signed doc has new element under root');

my($sig) = @children;
is($sig->localName, 'Signature', 'is a <Signature> element');
is($sig->namespaceURI, $dsig_ns, 'in xmldsig namespace');

my($c14n_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:CanonicalizationMethod/@Algorithm}
);
is($c14n_method, $uri_exc_c14n, 'c14n method from SignedInfo');

my($sig_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:SignatureMethod/@Algorithm}
);
is($sig_method, $uri_rsa_sha1, 'signature method from SignedInfo');

my($ref_uri) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/@URI}
);
is($ref_uri, '#' . $target_id, 'reference to signed element');

my @transforms = map { $_->to_literal } $xc->findnodes(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:Transforms/DSIG:Transform/@Algorithm}
);
is(scalar(@transforms), 2, '2 signature transforms');
is($transforms[0], $uri_env_sig, '1st transform');
is($transforms[1], $uri_exc_c14n, '2nd transform');

my($digest_method) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:DigestMethod/@Algorithm}
);
is($digest_method, $uri_sha1, 'digest method');

my($digest_from_xml) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignedInfo/DSIG:Reference/DSIG:DigestValue}
);

# Separate signature from signed doc
my($signature) = $signed =~ m{(<\w+:Signature\b.*</\w+:Signature>)}s;
$signed =~ s{<\w+:Signature\b.*</\w+:Signature>}{}s;
is($signed, $xml, 'source XML is otherwise unchanged');

my $bin_digest = sha1($xml);
my $sha1_digest = encode_base64($bin_digest, '');
is($sha1_digest, $digest_from_xml, 'manual digest matches digest from sig');

my($sig_value_from_xml) = $xc->findvalue(
    q{//DSIG:Signature/DSIG:SignatureValue}
);
$sig_value_from_xml =~ s/\s+//g;

my($sig_info) = $xc->findnodes(q{//DSIG:Signature/DSIG:SignedInfo});
my $plaintext = $sig_info->toStringEC14N(0, '', [$dsig_ns]);
my($key_text) = slurp_file($key_file);
my $rsa_key = Crypt::OpenSSL::RSA->new_private_key($key_text);
$rsa_key->use_pkcs1_padding();
my $bin_signature = $rsa_key->sign($plaintext);
my $sig_value = encode_base64($bin_signature, '');

is($sig_value, $sig_value_from_xml, 'base64 encoded signature');


##############################################################################
# Verify a signature

my $signed_xml = AuthenNZRealMeSigTestHelper::sign(
    key_file  => 'idp-assertion-sign-key.pem',
    xml_file  => 'xml-sigs-source.xml',
    sig_alg   => 'algorithm_sha1',
    command   => 'sign_one_ref',
    targets   => [ 'fourfivesix' ],
);

my $container_xml = <<EOF;
<container>
  <comment>This bit is outside the signed area and was added after signing</comment>
  $signed_xml
  <comment>Also outside the signed area and added after signing</comment>
</container>
EOF

my $idp_cert_file = test_conf_file('idp-assertion-sign-crt.pem');
my $verifier = eval {
    $sig_class->new(
        pub_cert_text  => slurp_file($idp_cert_file),
    );
};
is("$@", '', 'created object for verifying sigs');

my $result = eval {
    $verifier->verify('<document><title>Unsigned XML</title></document>');
};
is($result, undef, 'verification of unsigned document failed');
like("$@", qr{document contains no signatures}, 'with appropriate message');

$result = eval {
    $verifier->verify($signed_xml);
};
is("$@", '', 'verified sigs without throwing exception');
ok($result, 'verify method returned true');


##############################################################################
# Now try a doc with a bad signature

my $tampered_xml = $container_xml;
$tampered_xml =~ s/Pinetree/Mr 'Pinetree'/;

$result = eval {
    $verifier->verify($tampered_xml);
};
is($result, undef, 'verification of signed-but-tampered document failed');
like(
    "$@",
    qr{Digest of signed element 'fourfivesix' differs from that given in reference block},
    'with appropriate message'
);

done_testing();

exit;
