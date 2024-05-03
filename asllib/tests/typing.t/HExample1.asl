getter ReadMem[address : integer, size : integer, unknown : boolean] => bits(size*8)
begin
    var value : bits(size*8) = Zeros(size*8);
    value = Read(address, size, unknown);
    return value;
end

func Read(address : integer, size : integer, unknown : boolean) => bits(8*size)
begin
    var value : bits(size*8) = UNKNOWN : bits(size*8);
    if !unknown then
        value = MemRead(address, size);
    end
    return value;
end

func MemRead(address : integer, size : integer) => bits(8*size)
begin
    var result : bits(8*size);
    // Address of a special register
    if address == 0x800000000 then
        // Assuming input is integer{1, 2, 4, 8, 16}
        let regs = size DIV 4;
        // Perform multiple 4-bytes (32-bit) reads
        if size == 8 || size == 16 then
            for i = 1 to regs do
                let lsb = i - 1 * 32;
                result[lsb+31:lsb] = read_mem_bits(4);
            end
        else
            return read_mem_bits(4)[(8*size)-1:0];
        end
        return result;
    elsif address == 0x400000000 then
        result[31:0] = Ones(32);
        return result;
    else
        let val = read_mem_bits(size);
        return val[(8*size)-1:0];
    end
end

func read_mem_bits(size : integer) => bits(8*size)
begin
    return Ones(8*size);
end