/* Deathray - An Avisynth plug-in filter for spatial/temporal non-local means de-noising.
 *
 * version 1.01
 *
 * Copyright 2013, Jawed Ashraf - Deathray@cupidity.f9.co.uk
 */

__attribute__((reqd_work_group_size(8, 32, 1)))
__kernel void NLMMultiFrameFourPixel(
	read_only 	image2d_t 	target_plane,			// plane being filtered
	read_only 	image2d_t 	sample_plane,			// any other plane
	const		int			sample_equals_target,	// 1 when sample plane is target plane, 0 otherwise
	const		int			width,					// width in pixels
	const		int			height,					// height in pixels
	const		float		h,						// strength of denoising
	const		int			sample_expand,			// factor to expand sample radius
	constant	float		*g_gaussian,			// 49 weights of guassian kernel
	const		int			intermediate_width,		// width, in float4s, of intermediate buffers
	const		int			linear,					// process plane in linear space instead of gamma space
	global 		float4		*intermediate_average,	// intermediate average for 4 pixels
	global 		float4		*intermediate_weight) {	// intermediate weight for 4 pixels

	// Each work group produces 1024 filtered pixels, organised as a tile
	// of 32x32, for a single iteration of multi-pass filtering. Each 
	// iteration computes average and weight for each pixel based upon
	// the target plane and one other plane. After all passes have 
	// completed, another kernel is used to compute the final average
	// for each pixel based upon the intermediate average and weights
	// cumulatively produced by each pass.
	//
	// Each work item computes 4 pixels in a contiguous horizontal strip.
	//
	// The tile is bordered with an apron that's 8 pixels wide. This apron
	// consists of pixels from adjoining tiles, where available. If the
	// tile is at the frame edge, the apron is filled with pixels mirrored
	// from just inside the frame.
	//
	// Input plane contains pixels as uchars. UNORM8 format is defined,
	// so a read converts uchar into a normalised float of range 0.f to 1.f. 
	// 
	// Destination is a pair of float4 formatted buffers for average 
	// (weighted running sum) and weight (running sum of weights).

	__local float tile[TILE_SIDE * TILE_SIDE];

	int2 local_id;
	int2 source;
	Coordinates32x32(&local_id, &source);

	// Inside local memory the top-left corner of the tile is at (8,8)
	int2 target = (int2)((local_id.x << 2) + 8, local_id.y + 8);

	// The tile is 48x48 pixels which is entirely filled from the source
	FetchAndMirror48x48(target_plane, width, height, local_id, source, linear, tile) ;

	// Populate the 10x7 target window from the tile
	int kernel_radius = 3;
	float16 target_window[7];
	for (int y = 0; y < 2 * kernel_radius + 1; ++y) {
		target_window[y] = ReadTile16(target.x - kernel_radius,
									  target.y + y - kernel_radius, 
									  tile);
	}

	// Most planes are planes other than the target plane, which need
	// to be fetched into the tile for sampling
	if (!sample_equals_target)
		FetchAndMirror48x48(sample_plane, width, height, local_id, source, linear, tile);

	int linear_address = source.y * intermediate_width + source.x;
	float4 average = intermediate_average[linear_address];
	float4 weight = intermediate_weight[linear_address];

	Filter4(target, h, sample_expand, target_window, tile, g_gaussian, sample_equals_target, &average, &weight);

	if (target.y < height) {
		intermediate_average[linear_address] = average;
		intermediate_weight[linear_address] = weight;
	}
}

__attribute__((reqd_work_group_size(8, 32, 1)))
__kernel void NLMFinalise(
	read_only 				image2d_t 	target_plane,			// plane being filtered
	const		global 		float4		*intermediate_average,	// final average for 4 pixels
	const		global 		float4		*intermediate_weight,	// final weight for 4 pixels
	const					int			intermediate_width,		// width, in float4s, of intermediate buffers
	const		int			linear,								// process plane in linear space instead of gamma space
	write_only 				image2d_t 	destination_plane) {	// final result
	
	// Computes the final pixel value based upon the average and weight
	// values for each pixel generated by multiple filtering passes.
	//
	// Each work item computes 4 pixels in the result.
	//
	// Destination plane is formatted as UNORM8 uchar. The device 
	// automatically converts a pixel in range 0.f to 1.f into 0 to 255.

	int2 local_id;
	int2 destination;
	Coordinates32x32(&local_id, &destination);

	int linear_address = destination.y * intermediate_width + destination.x;

	float4 average = intermediate_average[linear_address];
	float4 weight = intermediate_weight[linear_address];

	float4 filtered_pixels = average / weight;

#if 1
	const sampler_t plane = CLK_NORMALIZED_COORDS_FALSE |
							CLK_ADDRESS_CLAMP |
							CLK_FILTER_NEAREST;

	float4 original = read_imagef(target_plane, plane, destination);

	float4 difference = filtered_pixels - original;
	float4 correction = (difference * original * original) - 
					    ((difference * original) * (difference * original));

	filtered_pixels = filtered_pixels - correction;
#endif
	WritePixel4(filtered_pixels, destination, linear, destination_plane);
}


