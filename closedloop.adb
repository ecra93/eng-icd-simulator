with Heart;
with HRM;
with ICD;
with ImpulseGenerator;
with Network;
with Measures;
with Principal; use Principal;

with Ada.Text_IO; use Ada.Text_IO;

package body ClosedLoop is

    -- declare variables to store each component of system
    Hrt : Heart.HeartType;
    Mon : HRM.HRMType;
    Def : ICD.ICDType;
    Gen : ImpulseGenerator.GeneratorType;
    Net : Network.Network;

    KnownPrincipals : access Network.PrincipalArray;
    Cardiologist, Assistant, Patient : Principal.PrincipalPtr;

    -- initialize the closed loop
    procedure Init is
    begin
        -- closed loop components
        Heart.Init(Hrt);
        HRM.Init(Mon);
        ICD.Init(Def);
        ImpulseGenerator.Init(Gen);

        -- authorized principals
        KnownPrincipals := new Network.PrincipalArray(0..2);
        Cardiologist := new Principal.Principal;
        Assistant := new Principal.Principal;
        Patient := new Principal.Principal;

        Principal.InitPrincipalForRole(Cardiologist.all,
            Principal.Cardiologist);
        Principal.InitPrincipalForRole(Assistant.all,
            Principal.ClinicalAssistant);
        Principal.InitPrincipalForRole(Patient.all,
            Principal.Patient);

        KnownPrincipals(0) := Cardiologist;
        KnownPrincipals(1) := Assistant;
        KnownPrincipals(2) := Patient;

        -- network interface
        Network.Init(Net, KnownPrincipals);
    end;

    -- turn the system off
    procedure RespondSwitchModeOff(Msg : Network.NetworkMessage) is
    begin
        -- authorized cardiologist or assistant can switch off
        if (Msg.MOffSource=Cardiologist or Msg.MOffSource=Assistant) then
            HRM.Off(Mon);
            ICD.Off(Def);
            ImpulseGenerator.Off(Gen);
        end if;
    end;

    -- turn the system of
    procedure RespondSwitchModeOn(Msg : Network.NetworkMessage) is
    begin
        -- authorized cardiologist or assitant can switch on
        if (Msg.MOnSource=Cardiologist or Msg.MOnSource=Assistant) then
            HRM.On(Mon, Hrt);
            ICD.On(Def);
            ImpulseGenerator.On(Gen);
        end if;
    end;

    -- format ICD representation of medical history to network represenation
    function GetMedicalHistory(Def: ICD.ICDType)
        return Network.RateHistory is
        ICDHistory : ICD.HistoryType;
        NetworkHistory : Network.RateHistory;
    begin
        -- fetch ICD representation of medical history
        ICDHistory := ICD.GetHistory(Def);
        -- then convert it to the network representation
        for I in ICD.HistoryIndex'First .. ICD.HistoryIndex'First+4 loop
            NetworkHistory(I+1).Rate := ICDHistory(I).Rate;
            NetworkHistory(I+1).Time := ICDHistory(I).Time;
        end loop;
        return NetworkHistory;
    end;

    -- respond with rate history confirmation/rejection
    procedure RespondReadRateHistoryRequest(Msg : Network.NetworkMessage) is
    begin
        -- authorized cardiologist, assistant, or patient
        if (Msg.HSource=Cardiologist or Msg.HSource=Assistant or
                Msg.HSource=Patient) then
            Network.SendMessage(Net,
                (MessageType => Network.ReadRateHistoryResponse,
                History => GetMedicalHistory(Def),
                HDestination => Msg.HSource));
        end if;
    end;

    -- respond with settings read confirmation/rejection
    procedure RespondReadSettingsRequest(Msg : Network.NetworkMessage) is
    begin
        -- authorized cardiolgoist or assistant
        -- must be in off mode
        if (Msg.RSource=Cardiologist or Msg.RSource=Assistant) and
                (not ICD.IsOn(Def)) then
            Network.SendMessage(Net,
                (MessageType => Network.ReadSettingsResponse,
                RDestination => Msg.RSource,
                RTachyBound => ICD.GetTachyThresh(Def),
                RJoulesToDeliver => ICD.GetTachyImpulse(Def)));
        end if;
    end;

    -- respond with settings change confirmation/rejection
    procedure RespondChangeSettingsRequest(Msg : Network.NetworkMessage) is
    begin
        -- authorized cardiologist or assistant
        -- must be in off mode
        if (Msg.CSource=Cardiologist or Msg.CSource=Assistant) and
                (not ICD.IsOn(Def)) then
            -- change settings
            -- set tachy thresh
            ICD.SetTachyThresh(Def, Msg.CTachyBound);
            -- set fib impulse
            ICD.SetFibImpulse(Def, Msg.CJoulesToDeliver);
            -- send response
            Network.SendMessage(Net,
                (MessageType => Network.ChangeSettingsResponse,
                CDestination => Msg.CSource));
        end if;
    end;

    -- checks if a message is authorized
    procedure RespondNetworkMessage(Msg : in Network.NetworkMessage) is
    begin
        case Msg.MessageType is
            when Network.ModeOn =>
                RespondSwitchModeOn(Msg);
            when Network.ModeOff => 
                RespondSwitchModeoff(Msg);
            when Network.ReadRateHistoryRequest =>
                RespondReadRateHistoryRequest(Msg);
            when Network.ReadSettingsRequest =>
                RespondReadSettingsRequest(Msg);
            when Network.ChangeSettingsRequest =>
                RespondChangeSettingsRequest(Msg);
            when others =>
                null;
        end case;
    end;

    -- simulate one tick of the clock
    procedure Tick is
        Msg : Network.NetworkMessage;
        MsgAvailable : Boolean;
        Rate: Measures.BPM;
        Impulse : Measures.Joules;
    begin
        -- Tick Network : check for new message and respond
        Network.Tick(Net);
        Network.GetNewMessage(Net, MsgAvailable, Msg);
        if MsgAvailable then
            RespondNetworkMessage(Msg);
        end if;

        -- Tick Heart & Monitor : collect most recent reading
        Heart.Tick(Hrt);
        HRM.Tick(Mon, Hrt);
        HRM.GetRate(Mon, Rate);
        
        -- Tick ICD : collect impulse
        ICD.Tick(Def, Rate);
        Impulse := ICD.GetImpulse(Def);

        -- pass impulse to generator
        ImpulseGenerator.SetImpulse(Gen, Impulse);
        ImpulseGenerator.Tick(Gen, Hrt);
    end;

end ClosedLoop;
