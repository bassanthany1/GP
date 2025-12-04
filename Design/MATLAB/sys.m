% Systolic Array Matrix Multiplication Verification
% Configuration: 8x20 * 20x8 = 8x8
clear; clc;

% Matrix dimensions
M = 8;  % rows of A
K = 20; % inner dimension (cols of A, rows of B)
N = 8;  % cols of B

% Generate random int8 matrices
A = int8(randi([-128, 127], M, K));
B = int8(randi([-128, 127], K, N));

% Compute expected result using double precision then convert
% MATLAB doesn't support direct integer matrix multiplication
A_double = double(A);
B_double = double(B);
C_double = A_double * B_double;

% MATLAB's int16() uses SATURATION on overflow:
% Values > 32767 saturate to 32767
% Values < -32768 saturate to -32768
C_expected = int16(C_double);  % Convert to int16 (matches 2*DATAWIDTH = 16 bits)

% Check for overflow/saturation
overflow_count = sum(sum(C_double > 32767 | C_double < -32768));
if overflow_count > 0
    fprintf('\n*** WARNING: %d elements overflowed int16 range! ***\n', overflow_count);
    fprintf('MATLAB int16() uses SATURATION (clips to -32768 or 32767)\n');
    fprintf('Your hardware uses WRAPPING (2''s complement overflow)\n');
    fprintf('Consider reducing input range or increasing output width.\n\n');
    
    % Compute hardware-style wrapping for comparison
    C_wrapped = int16(mod(C_double + 32768, 65536) - 32768);
    
    % Show the overflow details
    fprintf('Overflow details:\n');
    for i = 1:M
        for j = 1:N
            if C_double(i,j) > 32767 || C_double(i,j) < -32768
                fprintf('  C[%d][%d]: %.0f -> MATLAB saturates to %d, Hardware wraps to %d\n', ...
                        i-1, j-1, C_double(i,j), C_expected(i,j), C_wrapped(i,j));
            end
        end
    end
    
    fprintf('\n*** Using WRAPPED values for hardware verification ***\n');
    C_expected = C_wrapped;  % Use wrapped values to match hardware behavior
end

% Display matrices
disp('Matrix A (8x20):');
disp(A);
disp(' ');

disp('Matrix B (20x8):');
disp(B);
disp(' ');

disp('Expected Result C (8x8):');
disp(C_expected);
disp(' ');

%% Generate SystemVerilog format for testbench

fprintf('\n========== SYSTEMVERILOG TESTBENCH DATA ==========\n\n');

% Generate A matrix initialization
fprintf('// Matrix A (8x20) - int8 format\n');
fprintf('logic signed [7:0] A [0:%d][0:%d] = ''{\n', M-1, K-1);
for i = 1:M
    fprintf('    {');
    for j = 1:K
        if j < K
            fprintf('%d, ', A(i,j));
        else
            fprintf('%d', A(i,j));
        end
    end
    if i < M
        fprintf('},\n');
    else
        fprintf('}\n');
    end
end
fprintf('};\n\n');

% Generate B matrix initialization
fprintf('// Matrix B (20x8) - int8 format\n');
fprintf('logic signed [7:0] B [0:%d][0:%d] = ''{\n', K-1, N-1);
for i = 1:K
    fprintf('    {');
    for j = 1:N
        if j < N
            fprintf('%d, ', B(i,j));
        else
            fprintf('%d', B(i,j));
        end
    end
    if i < K
        fprintf('},\n');
    else
        fprintf('}\n');
    end
end
fprintf('};\n\n');

% Generate expected C matrix
fprintf('// Expected Result C (8x8) - int16 format (2*DATAWIDTH)\n');
fprintf('logic signed [15:0] C_expected [0:%d][0:%d] = ''{\n', M-1, N-1);
for i = 1:M
    fprintf('    {');
    for j = 1:N
        if j < N
            fprintf('%d, ', C_expected(i,j));
        else
            fprintf('%d', C_expected(i,j));
        end
    end
    if i < M
        fprintf('},\n');
    else
        fprintf('}\n');
    end
end
fprintf('};\n\n');

%% Save to files for SystemVerilog testbench
fid = fopen('matrix_A1.txt', 'w');
for i = 1:M
    for j = 1:K
        fprintf(fid, '%d', A(i,j));
        if j < K
            fprintf(fid, ' ');
        end
    end
    fprintf(fid, '\n');
end
fclose(fid);

fid = fopen('matrix_B1.txt', 'w');
for i = 1:K
    for j = 1:N
        fprintf(fid, '%d', B(i,j));
        if j < N
            fprintf(fid, ' ');
        end
    end
    fprintf(fid, '\n');
end
fclose(fid);

fid = fopen('matrix_C_expected1.txt', 'w');
for i = 1:M
    for j = 1:N
        fprintf(fid, '%d', C_expected(i,j));
        if j < N
            fprintf(fid, ' ');
        end
    end
    fprintf(fid, '\n');
end
fclose(fid);

fprintf('\n=== FILES SAVED ===\n');
disp('Matrices saved to:');
disp('  - matrix_A.txt      (8x20 int8 matrix)');
disp('  - matrix_B.txt      (20x8 int8 matrix)');
disp('  - matrix_C_expected.txt (8x8 int16 matrix)');
disp(' ');
disp('Place these files in the same directory as your SystemVerilog testbench.');

%% Calculate systolic array timing
TOTAL_CYCLES = K + M + N - 2;
fprintf('\nSystolic Array Timing:\n');
fprintf('  Total computation cycles: %d\n', TOTAL_CYCLES);
fprintf('  Cycles after load_data pulse: %d\n', TOTAL_CYCLES + 1);
fprintf('  valid_out should assert at cycle: %d\n', TOTAL_CYCLES + 1);