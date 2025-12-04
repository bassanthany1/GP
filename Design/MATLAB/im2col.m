% ============================================================
% im2col Tile Generator - MATLAB Implementation
% Replicates im2col2.sv functionality using built-in im2col
% ============================================================

clear; clc;

% Parameters (matching SystemVerilog module)
IMG_W = 28;
IMG_H = 28;
KERNEL_SIZE = 5;
STRIDE = 1;
TILE_ROWS = 8;
IN_CHANNELS = 1;

% Calculate output dimensions
OUT_W = floor((IMG_W - KERNEL_SIZE) / STRIDE) + 1;
OUT_H = floor((IMG_H - KERNEL_SIZE) / STRIDE) + 1;
TOTAL_WINDOWS = OUT_W * OUT_H;

fprintf('Output dimensions: %dx%d\n', OUT_W, OUT_H);
fprintf('Total windows: %d\n', TOTAL_WINDOWS);
fprintf('Number of tiles: %d\n\n', ceil(TOTAL_WINDOWS / TILE_ROWS));

% Load and preprocess image
% Read from the same hex file that the testbench uses
fprintf('Reading image from image_hex.mem...\n');
fid = fopen('image_hex.mem', 'r');
if fid == -1
    error('Cannot open image_hex.mem. Make sure the file exists.');
end

% Read hex values
img_flat = [];
while ~feof(fid)
    line = fgetl(fid);
    if ischar(line) && ~isempty(line)
        % Convert hex string to decimal
        val = hex2dec(line);
        img_flat = [img_flat; val];
    end
end
fclose(fid);

% Verify we got the right number of pixels
expected_pixels = IMG_H * IMG_W * IN_CHANNELS;
if length(img_flat) ~= expected_pixels
    error('Expected %d pixels but got %d from image_hex.mem', expected_pixels, length(img_flat));
end

% Reshape to image array [H x W] for single channel
% Data is stored as: channel, row, col (flattened)
img = zeros(IMG_H, IMG_W, 'uint8');
idx = 1;
for c = 1:IN_CHANNELS
    for y = 1:IMG_H
        for x = 1:IMG_W
            img(y, x) = img_flat(idx);
            idx = idx + 1;
        end
    end
end

fprintf('Image loaded successfully from image_hex.mem\n');

fprintf('Image size: %dx%d\n', size(img, 1), size(img, 2));
fprintf('Data type: %s\n', class(img));
fprintf('Value range: [%d, %d]\n\n', min(img(:)), max(img(:)));

% Display original image (optional - comment out if not needed)
% figure('Name', 'Original Image');
% imshow(uint8(img));
% title('Original 28x28 Grayscale Image');

% Use im2col to extract sliding windows
% im2col extracts KERNEL_SIZE x KERNEL_SIZE blocks
% 'sliding' mode extracts overlapping windows
% NOTE: im2col works in COLUMN-MAJOR order and may reorder pixels

% For precise control, manually extract windows to match RTL behavior
total_windows = OUT_W * OUT_H;
col_data = zeros(total_windows, KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS, 'uint8');

window_idx = 1;
for out_y = 0:(OUT_H-1)
    for out_x = 0:(OUT_W-1)
        % Calculate starting position in original image
        img_y_start = out_y * STRIDE + 1;  % +1 for MATLAB 1-based indexing
        img_x_start = out_x * STRIDE + 1;
        
        % Extract KERNEL_SIZE x KERNEL_SIZE window
        pixel_idx = 1;
        for c = 1:IN_CHANNELS
            for ky = 0:(KERNEL_SIZE-1)
                for kx = 0:(KERNEL_SIZE-1)
                    img_y = img_y_start + ky;
                    img_x = img_x_start + kx;
                    col_data(window_idx, pixel_idx) = img(img_y, img_x);
                    pixel_idx = pixel_idx + 1;
                end
            end
        end
        window_idx = window_idx + 1;
    end
end

% Organize into tiles
num_tiles = ceil(TOTAL_WINDOWS / TILE_ROWS);
tiles = cell(num_tiles, 1);

for tile_idx = 1:num_tiles
    start_window = (tile_idx - 1) * TILE_ROWS + 1;
    end_window = min(tile_idx * TILE_ROWS, TOTAL_WINDOWS);
    num_rows = end_window - start_window + 1;
    
    % Extract windows for this tile (already in row format)
    tile_data = col_data(start_window:end_window, :);
    tiles{tile_idx} = tile_data;
    
    % Display tile information
    fprintf('=== TILE %d ===\n', tile_idx);
    fprintf('Windows: %d to %d (%d rows)\n', start_window, end_window, num_rows);
    fprintf('Tile shape: %d x %d (rows x elements per window)\n\n', ...
            size(tile_data, 1), size(tile_data, 2));
    
    % Removed visualization - data only saved to files
end

% Save image in hex format for $readmemh
fid = fopen('image_hex.mem', 'w');
for c = 1:IN_CHANNELS
    for y = 1:IMG_H
        for x = 1:IMG_W
            fprintf(fid, '%02X\n', img(y, x));
        end
    end
end
fclose(fid);
fprintf('Saved: image_hex.mem\n');

% Also save in decimal format for verification
fid = fopen('image_decimal.txt', 'w');
fprintf(fid, 'Image data in [channel][row][col] format:\n');
fprintf(fid, 'Size: %dx%d, Channels: %d\n\n', IMG_H, IMG_W, IN_CHANNELS);
for c = 1:IN_CHANNELS
    fprintf(fid, 'Channel %d:\n', c-1);
    for y = 1:IMG_H
        for x = 1:IMG_W
            fprintf(fid, '%3d ', img(y, x));
        end
        fprintf(fid, '\n');
    end
    fprintf(fid, '\n');
end
fclose(fid);
fprintf('Saved: image_decimal.txt\n');
fprintf('\n=== SUMMARY ===\n');
fprintf('Total tiles generated: %d\n', num_tiles);
fprintf('Total windows processed: %d\n', TOTAL_WINDOWS);
fprintf('Data format: uint8 (range 0-255)\n');
fprintf('Each window size: %d elements (%dx%d kernel)\n', ...
        KERNEL_SIZE*KERNEL_SIZE, KERNEL_SIZE, KERNEL_SIZE);

% Save all tiles to text files
fprintf('\n=== SAVING DATA ===\n');

% Save all windows in one file
fid = fopen('all_windows9.txt', 'w');
fprintf(fid, 'All Windows Data (each row is one %dx%d window)\n', KERNEL_SIZE, KERNEL_SIZE);
fprintf(fid, 'Total windows: %d\n', TOTAL_WINDOWS);
fprintf(fid, 'Format: uint8 (0-255)\n');
fprintf(fid, '====================================\n\n');
for i = 1:TOTAL_WINDOWS
    fprintf(fid, 'Window %d: ', i);
    fprintf(fid, '%3d ', col_data(i, :));
    fprintf(fid, '\n');
end
fclose(fid);
fprintf('Saved: all_windows.txt\n');

% Save each tile to separate files
for tile_idx = 1:num_tiles
    filename = sprintf('tile_%d.txt', tile_idx);
    fid = fopen(filename, 'w');
    
    tile_data = tiles{tile_idx};
    num_rows = size(tile_data, 1);
    start_window = (tile_idx - 1) * TILE_ROWS + 1;
    
    fprintf(fid, 'Tile %d\n', tile_idx);
    fprintf(fid, 'Windows: %d to %d\n', start_window, start_window + num_rows - 1);
    fprintf(fid, 'Rows: %d, Columns: %d\n', size(tile_data, 1), size(tile_data, 2));
    fprintf(fid, '====================================\n\n');
    
    for row = 1:num_rows
        fprintf(fid, 'Row %d (Window %d): ', row, start_window + row - 1);
        fprintf(fid, '%3d ', tile_data(row, :));
        fprintf(fid, '\n');
    end
    
    fclose(fid);
    fprintf('Saved: %s\n', filename);
end

% Save summary information
fid = fopen('summary.txt', 'w');
fprintf(fid, '=== IM2COL TILE GENERATION SUMMARY ===\n\n');
fprintf(fid, 'Parameters:\n');
fprintf(fid, '  Image size: %dx%d\n', IMG_H, IMG_W);
fprintf(fid, '  Kernel size: %dx%d\n', KERNEL_SIZE, KERNEL_SIZE);
fprintf(fid, '  Stride: %d\n', STRIDE);
fprintf(fid, '  Tile rows: %d\n', TILE_ROWS);
fprintf(fid, '  Input channels: %d\n\n', IN_CHANNELS);
fprintf(fid, 'Output:\n');
fprintf(fid, '  Output dimensions: %dx%d\n', OUT_W, OUT_H);
fprintf(fid, '  Total windows: %d\n', TOTAL_WINDOWS);
fprintf(fid, '  Total tiles: %d\n', num_tiles);
fprintf(fid, '  Elements per window: %d\n', KERNEL_SIZE*KERNEL_SIZE*IN_CHANNELS);
fprintf(fid, '  Data format: uint8 (0-255)\n\n');
fprintf(fid, 'Files generated:\n');
fprintf(fid, '  - all_windows.txt: All windows data\n');
for i = 1:num_tiles
    fprintf(fid, '  - tile_%d.txt: Tile %d data\n', i, i);
end
fprintf(fid, '  - summary.txt: This file\n');
fclose(fid);
fprintf('Saved: summary.txt\n');

fprintf('\nAll data saved successfully!\n');