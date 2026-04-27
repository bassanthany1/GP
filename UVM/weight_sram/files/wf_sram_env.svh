   // =========================================================================
    // 8. ENV
    // =========================================================================
    class wf_sram_env extends uvm_env;
        `uvm_component_utils(wf_sram_env)

        wf_sram_agent      agent;
        wf_sram_scoreboard scoreboard;
        wf_sram_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = wf_sram_agent     ::type_id::create("agent",      this);
            scoreboard = wf_sram_scoreboard::type_id::create("scoreboard", this);
            coverage   = wf_sram_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // Single fan-out: monitor -> scoreboard AND coverage
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 