% ============================================================
% MATLAB Model: weight module (SRAM-based)
% Description: Models weight loading from SRAM memory file
% Converts linear SRAM array into tiles [WEIGHTS_PER_FILTER][ARRAY_COLS]
% ============================================================

function [tiles, num_tiles] = weight_sram_model(sram_weight_data, KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, ARRAY_COLS)
    % Inputs:
    %   sram_weight_data: 1D array containing all weights from SRAM
    %   KERNEL_SIZE: Kernel size (e.g., 5 for 5x5)
    %   IN_CHANNELS: Number of input channels
    %   OUT_CHANNELS: Number of output channels
    %   ARRAY_COLS: Number of columns in systolic array
    %
    % Outputs:
    %   tiles: Cell array where each cell contains a tile of size [WEIGHTS_PER_FILTER, ARRAY_COLS]
    %   num_tiles: Number of tiles generated
    
    % Calculate parameters
    WEIGHTS_PER_FILTER = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    TOTAL_WEIGHTS = OUT_CHANNELS * WEIGHTS_PER_FILTER;
    num_tiles = ceil(OUT_CHANNELS / ARRAY_COLS);
    
    % Verify input size
    if length(sram_weight_data) < TOTAL_WEIGHTS
        error('SRAM data size (%d) is less than required (%d)', length(sram_weight_data), TOTAL_WEIGHTS);
    end
    
    % Initialize cell array to store tiles
    tiles = cell(num_tiles, 1);
    
    % Process each tile
    for tile_idx = 0:(num_tiles-1)
        % Initialize current tile with zeros
        tile_buf = zeros(WEIGHTS_PER_FILTER, ARRAY_COLS);
        
        % Fill each row and column of the tile
        for r = 0:(WEIGHTS_PER_FILTER-1)
            for c = 0:(ARRAY_COLS-1)
                % Calculate output channel index
                oc = tile_idx * ARRAY_COLS + c;
                
                if oc < OUT_CHANNELS
                    % Calculate SRAM address: oc*WEIGHTS_PER_FILTER + r
                    sram_addr = oc * WEIGHTS_PER_FILTER + r + 1; % +1 for MATLAB 1-based indexing
                    tile_buf(r+1, c+1) = sram_weight_data(sram_addr);
                else
                    % Padding with zeros
                    tile_buf(r+1, c+1) = 0;
                end
            end
        end
        
        % Store the tile
        tiles{tile_idx+1} = tile_buf;
    end
end

% ============================================================
% Load Memory File (.mem format)
% ============================================================
function data = load_mem_file(filename)
    % Load .mem file containing hexadecimal or decimal values
    % Supports formats:
    %   - Hex: @address hex_value
    %   - Hex: hex_value (one per line)
    %   - Decimal: decimal_value (one per line)
    
    fprintf('Loading memory file: %s\n', filename);
    
    if ~exist(filename, 'file')
        error('Memory file not found: %s', filename);
    end
    
    fid = fopen(filename, 'r');
    if fid == -1
        error('Cannot open file: %s', filename);
    end
    
    data = [];
    line_num = 0;
    
    while ~feof(fid)
        line = fgetl(fid);
        line_num = line_num + 1;
        
        if ~ischar(line)
            continue;
        end
        
        % Remove comments and whitespace
        line = strtrim(line);
        comment_idx = strfind(line, '//');
        if ~isempty(comment_idx)
            line = line(1:comment_idx-1);
            line = strtrim(line);
        end
        
        if isempty(line)
            continue;
        end
        
        % Parse line
        if startsWith(line, '@')
            % Format: @address value
            tokens = strsplit(line);
            if length(tokens) >= 2
                value_str = tokens{2};
                value = hex2dec(value_str);
                data = [data; value];
            end
        else
            % Try hex first, then decimal
            try
                value = hex2dec(line);
                data = [data; value];
            catch
                try
                    value = str2double(line);
                    if ~isnan(value)
                        data = [data; value];
                    end
                catch
                    fprintf('Warning: Cannot parse line %d: %s\n', line_num, line);
                end
            end
        end
    end
    
    fclose(fid);
    fprintf('Loaded %d values from memory file\n', length(data));
end

% ============================================================
% Display Tiles
% ============================================================
function display_tiles(tiles, num_tiles, WEIGHTS_PER_FILTER, ARRAY_COLS)
    fprintf('\n========== MATLAB Tile Output ==========\n\n');
    
    for t = 1:num_tiles
        fprintf('------ Tile %d Ready ------\n', t-1);
        
        for r = 1:WEIGHTS_PER_FILTER
            fprintf('Row %d: ', r-1);
            for c = 1:ARRAY_COLS
                fprintf('%d ', tiles{t}(r, c));
            end
            fprintf('\n');
        end
        
        fprintf('-------------------------\n\n');
    end
end

% ============================================================
% Save Tiles to File
% ============================================================
function save_tiles_to_file(tiles, filename, WEIGHTS_PER_FILTER, ARRAY_COLS)
    fid = fopen(filename, 'w');
    
    for t = 1:length(tiles)
        fprintf(fid, '------ Tile %d Ready ------\n', t-1);
        
        for r = 1:WEIGHTS_PER_FILTER
            fprintf(fid, 'Row %d: ', r-1);
            for c = 1:ARRAY_COLS
                fprintf(fid, '%d ', tiles{t}(r, c));
            end
            fprintf(fid, '\n');
        end
        
        fprintf(fid, '-------------------------\n\n');
    end
    
    fclose(fid);
    fprintf('Tiles saved to: %s\n', filename);
end

% ============================================================
% Test Function
% ============================================================
function test_weight_sram_model()
    fprintf('=== Testing Weight SRAM Model ===\n\n');
    
    % Parameters - MUST MATCH SystemVerilog module
    KERNEL_SIZE = 5;
    IN_CHANNELS = 1;
    OUT_CHANNELS = 6;
    ARRAY_COLS = 3;
    DATA_WIDTH = 8;
    
    WEIGHTS_PER_FILTER = KERNEL_SIZE * KERNEL_SIZE * IN_CHANNELS;
    TOTAL_WEIGHTS = OUT_CHANNELS * WEIGHTS_PER_FILTER;
    
    fprintf('Parameters:\n');
    fprintf('  KERNEL_SIZE = %d\n', KERNEL_SIZE);
    fprintf('  IN_CHANNELS = %d\n', IN_CHANNELS);
    fprintf('  OUT_CHANNELS = %d\n', OUT_CHANNELS);
    fprintf('  ARRAY_COLS = %d\n', ARRAY_COLS);
    fprintf('  WEIGHTS_PER_FILTER = %d\n', WEIGHTS_PER_FILTER);
    fprintf('  TOTAL_WEIGHTS = %d\n\n', TOTAL_WEIGHTS);
    
    % Try to load from memory file
    mem_filename = 'tfl.pseudo_qconst9.mem';
    
    if exist(mem_filename, 'file')
        fprintf('Loading weights from: %s\n\n', mem_filename);
        sram_weight_data = load_mem_file(mem_filename);
        
        % Verify size
        if length(sram_weight_data) < TOTAL_WEIGHTS
            fprintf('Warning: Memory file has %d values, but need %d\n', ...
                    length(sram_weight_data), TOTAL_WEIGHTS);
            fprintf('Padding with zeros...\n');
            sram_weight_data = [sram_weight_data; zeros(TOTAL_WEIGHTS - length(sram_weight_data), 1)];
        end
    else
        fprintf('Memory file not found: %s\n', mem_filename);
        fprintf('Generating sequential test data instead...\n\n');
        
        % Generate sequential test data (1, 2, 3, ..., saturating at 255)
        MAX_VAL = 2^DATA_WIDTH - 1;
        sram_weight_data = min((1:TOTAL_WEIGHTS)', MAX_VAL);
    end
    
    % Display sample of loaded data
    fprintf('First 25 values from SRAM:\n');
    fprintf('  ');
    for i = 1:min(25, length(sram_weight_data))
        fprintf('%3d ', sram_weight_data(i));
        if mod(i, 5) == 0
            fprintf('\n  ');
        end
    end
    fprintf('\n\n');
    
    % Run the weight loading model
    [tiles, num_tiles] = weight_sram_model(sram_weight_data, KERNEL_SIZE, IN_CHANNELS, OUT_CHANNELS, ARRAY_COLS);
    
    fprintf('Number of tiles generated: %d\n', num_tiles);
    fprintf('Tile dimensions: [%d x %d]\n\n', size(tiles{1}, 1), size(tiles{1}, 2));
    
    % Display tiles
    display_tiles(tiles, num_tiles, WEIGHTS_PER_FILTER, ARRAY_COLS);
    
    % Save to file
    save_tiles_to_file(tiles, 'matlab_sram_tiles_output.txt', WEIGHTS_PER_FILTER, ARRAY_COLS);
    
    % Verification
    total_weights = 0;
    max_value = 0;
    for t = 1:num_tiles
        total_weights = total_weights + sum(tiles{t}(:) ~= 0);
        max_value = max(max_value, max(tiles{t}(:)));
    end
    
    expected_weights = OUT_CHANNELS * WEIGHTS_PER_FILTER;
    fprintf('\nVerification:\n');
    fprintf('  Expected total weights: %d\n', expected_weights);
    fprintf('  Actual weights in tiles: %d\n', total_weights);
    fprintf('  Maximum value in tiles: %d (should be <= %d)\n', max_value, 2^DATA_WIDTH - 1);
    
    if total_weights == expected_weights
        fprintf('  ✓ PASS: All weights accounted for!\n');
    else
        fprintf('  ✗ FAIL: Weight count mismatch!\n');
    end
    
    if max_value <= 2^DATA_WIDTH - 1
        fprintf('  ✓ PASS: All values within %d-bit range!\n', DATA_WIDTH);
    else
        fprintf('  ✗ FAIL: Values exceed %d-bit range!\n', DATA_WIDTH);
    end
end

% ============================================================
% Run Test
% ============================================================
test_weight_sram_model();

fprintf('\n========================================\n');
fprintf('Usage:\n');
fprintf('1. Place "tfl.pseudo_qconst9.mem" in the same directory\n');
fprintf('2. Run this script\n');
fprintf('3. Compare output with SystemVerilog simulation\n');
fprintf('========================================\n');