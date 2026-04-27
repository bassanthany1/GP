   // =========================================================================
    // 8. ENV
    // =========================================================================
    class bs_sram_env extends uvm_env;
        `uvm_component_utils(bs_sram_env)

        bs_sram_agent      agent;
        bs_sram_scoreboard scoreboard;
        bs_sram_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = bs_sram_agent     ::type_id::create("agent",      this);
            scoreboard = bs_sram_scoreboard::type_id::create("scoreboard", this);
            coverage   = bs_sram_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass