   // =========================================================================
    // 8. ENV
    // =========================================================================
    class fm_env extends uvm_env;
        `uvm_component_utils(fm_env)

        fm_agent      agent;
        fm_scoreboard scoreboard;
        fm_coverage   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent      = fm_agent     ::type_id::create("agent",      this);
            scoreboard = fm_scoreboard::type_id::create("scoreboard", this);
            coverage   = fm_coverage  ::type_id::create("coverage",   this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.ap.connect(scoreboard.analysis_export);
            agent.ap.connect(coverage.analysis_export);
        endfunction

    endclass 