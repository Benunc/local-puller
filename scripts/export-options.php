<?php
/**
 * Export pushable wp_options to JSON (for push-db-to-live).
 * Run in WP context: wp eval-file scripts/export-options.php [exclude-file]
 * Reads exclude list (option names or prefixes); outputs JSON to stdout.
 */
// Run in WP context via: wp eval-file scripts/export-options.php [exclude-file]
if ( ! defined( 'ABSPATH' ) && ! ( defined( 'WP_CLI' ) && WP_CLI ) ) {
	fwrite( STDERR, "Run via: wp eval-file scripts/export-options.php [exclude-file]\n" );
	exit( 1 );
}

$exclude_file = $argv[1] ?? '';
$exclude = array();
if ( $exclude_file && is_readable( $exclude_file ) ) {
	$lines = file( $exclude_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES );
	foreach ( $lines as $line ) {
		$line = trim( $line );
		if ( $line === '' || strpos( $line, '#' ) === 0 ) {
			continue;
		}
		$exclude[] = $line;
	}
}

global $wpdb;
$table = $wpdb->options;
$rows = $wpdb->get_results( "SELECT option_name, option_value FROM {$table}", OBJECT_K );

$out = array();
foreach ( $rows as $name => $row ) {
	$skip = false;
	foreach ( $exclude as $pattern ) {
		if ( $pattern === $name ) {
			$skip = true;
			break;
		}
		// Prefix match: pattern ending in _ matches option_name that starts with it
		if ( substr( $pattern, -1 ) === '_' && strpos( $name, $pattern ) === 0 ) {
			$skip = true;
			break;
		}
	}
	if ( $skip ) {
		continue;
	}
	$out[ $name ] = maybe_unserialize( $row->option_value );
}

echo json_encode( $out, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT );
