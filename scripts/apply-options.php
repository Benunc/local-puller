<?php
/**
 * Apply exported options JSON on live (run on server in WP context).
 * wp eval-file apply-options.php /path/to/options.json
 */
if ( ! defined( 'ABSPATH' ) && ! ( defined( 'WP_CLI' ) && WP_CLI ) ) {
	exit( 'Run via: wp eval-file apply-options.php <options.json>' );
}

// WP-CLI eval-file may not pass extra args to $argv; support env var from push script
$json_file = getenv( 'OPTIONS_JSON_PATH' ) ?: ( $argv[1] ?? '' );
if ( ! $json_file || ! is_readable( $json_file ) ) {
	fwrite( STDERR, "Usage: OPTIONS_JSON_PATH=/path/to/options.json wp eval-file apply-options.php\n" );
	fwrite( STDERR, "   or: wp eval-file apply-options.php <options.json>\n" );
	exit( 1 );
}

$json = file_get_contents( $json_file );
$data = json_decode( $json, true );
if ( ! is_array( $data ) ) {
	fwrite( STDERR, "Invalid JSON in options file.\n" );
	exit( 1 );
}

$count = 0;
foreach ( $data as $option_name => $value ) {
	update_option( $option_name, $value );
	$count++;
}

echo "Applied {$count} options.\n";
