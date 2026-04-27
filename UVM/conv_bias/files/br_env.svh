    // =========================================================================
    // 8. ENV
    // =========================================================================
    class br_env extends uvm_env;
        `uvm_component_utils(br_env)

        br_agent      agent;
        br_scoreboard scoreboard;
        br_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = br_agent     ::type_id::create("agent",      this);
            scoreboard = br_scoreboard::type_id::create("scoreboard", this);
            coverage   = br_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass